{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE TemplateHaskell, DeriveDataTypeable, DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Worker where

import Control.Distributed.Process
  hiding (Message, mask, finally, handleMessage, proxy)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Concurrent.Async
import Control.Monad
import Control.Concurrent.STM
import Control.Concurrent
import Text.Printf
import Network
import System.IO
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.List as List
import qualified Data.UUID as U       -- UUID
import qualified Data.UUID.V4 as U4   -- UUID
import Control.Exception
import Data.Char
import KVStore

-- Every node will be equal (master)
master :: Backend -> String -> String -> String -> Process ()
master backend port ring_size ring_id = do
    mynode <- getSelfNode
    -- Peer discovery
    peers0 <- liftIO $ findPeers backend 1000000
    let peers = filter (/= mynode) peers0
    say ("peers are " ++ show peers)
    mypid <- getSelfPid
    -- Register my own server process
    register "dNode" mypid
    -- Send join request to the clster
    forM_ peers $ \peer -> do
      whereisRemoteAsync peer "dNode"
    -- Start!
    dNode (read port :: Int) (read ring_size :: Int) (read ring_id :: Int)


-- Start a new distributed server
dNode :: Int -> Int -> Int -> Process ()
dNode port rsize rid = do
    server@Server{..} <- newNode [] rsize rid  -- create a new server instance
    _ <- ($) liftIO $ forkIO (socketListener server port)
    _ <- spawnLocal $ forever $ join $ liftIO $ atomically $ readTChan proxychan -- proxy
    forever $
         -- receiveWait :: [Match b] -> Process b
        receiveWait [ 
            match $ handleRemoteMessage server,
            match $ handleMonitorNotification server,
            matchIf (\(WhereIsReply l _) -> l == "dNode") $ handleWhereIsReply server,
            matchAny $ \_ -> return ()      -- ignore unknown messages
          ]

--------------------------------------------------------------------------------

-- Create a new server
newNode :: [ProcessId] -> Int -> Int -> Process Server
newNode pids rsize rid = do
  pid <- getSelfPid
  liftIO $ do
    s <- newTVarIO pids
    c <- newTVarIO Map.empty
    x <- newTVarIO (0, 0)
    v <- newTVarIO Map.empty
    m <- newTVarIO Map.empty
    o <- newTChanIO
    p <- newTVarIO [(rid, pid)]
    f <- newTVarIO $ Map.fromList $ map (\t -> (t, (rid, pid)))
         [0 .. floor (logBase 2.0 (fromIntegral rsize)) - 1]
    d <- newTVarIO Map.empty
    return Server { clients = c, servers = s, proxychan = o, spid = pid,
                    peers = p, ftable = f, ringSize = rsize, ringId = rid,
                    counter = x, votes = v, messages = m, mmdb = d }

--------------------------------------------------------------------------------

-- The listener in the forked thread
socketListener :: Server -> Int -> IO ()
socketListener server port = withSocketsDo $ do
  sock <- listenOn (PortNumber (fromIntegral port))
  printf "Listening on port %d\n" port
  forever $ do
      (h, addr, p) <- accept sock
      printf "Accepted connection from %s: %s\n" addr (show p)
      forkFinally (talk server h) (\_ -> hClose h)

-- Read the client identifier (unique)
talk :: Server -> Handle -> IO ()
talk server@Server{..} h = do
    hSetNewlineMode h universalNewlineMode
    hSetBuffering h LineBuffering
    readName
  where
    readName = do
      hPutStrLn h "Enter your ID:"
      name <- hGetLine h
      if null name then readName
      else mask $ \restore -> do
        client <- atomically $ newLocalClient name h
        ok <- atomically $ checkAddClient server (ClientLocal client)
        if not ok then restore $ do
          hPrintf h "The name %s is in use, please choose another\n" name
          readName
        else do
          atomically $ sendRemoteAll server (MsgNewClient name spid)
          restore (runClient server client) `finally` disconnectLocalClient server name

-- Run the local client
runClient :: Server -> LocalClient -> IO ()
runClient serv@Server{..} client@LocalClient{..} = do
    _ <- race server receive
    return ()
  where server = join $ atomically $ do
          k <- readTVar clientKicked
          case k of
            Nothing -> do
              msg <- readTChan clientSendChan
              return $ do continue <- handleMessage serv client msg
                          when continue server
            Just reason -> return $
              hPutStrLn clientHandle $ "You have been kicked: " ++ reason
        receive = forever $ do msg <- hGetLine clientHandle
                               atomically $ sendLocal client (Command msg)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--                          >> MESSAGE PASSING <<
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

-- Send PMessage to the local node
sendLocal :: LocalClient -> Message -> STM ()
sendLocal LocalClient{..} = writeTChan clientSendChan

-- Send PMessage to a remote node
sendRemote :: Server -> ProcessId -> PMessage -> STM ()
sendRemote Server{..} pid pmsg = writeTChan proxychan (send pid pmsg)

-- Send PMessage to all the remote nodes
sendRemoteAll :: Server -> PMessage -> STM ()
sendRemoteAll server@Server{..} pmsg = do
    pids <- readTVar servers
    mapM_ (\pid -> sendRemote server pid pmsg) pids

-- Broadcase local clients
broadcastLocal :: Server -> Message -> STM ()
broadcastLocal Server{..} msg = do
    clientmap <- readTVar clients
    mapM_ sendIfLocal (Map.elems clientmap)
  where
    sendIfLocal (ClientLocal c)  = sendLocal c msg
    sendIfLocal (ClientRemote _) = return ()

-- Broadcase all clients (remote and local)
broadcast :: Server -> Message -> STM ()
broadcast server@Server{..} msg = do
    sendRemoteAll server (MsgBroadcast msg)
    broadcastLocal server msg

kick :: Server -> CName -> CName -> STM ()
kick = undefined

tell :: Server -> LocalClient -> CName -> String -> IO ()
tell server@Server{..} LocalClient{..} who msg = do
  ok <- atomically $ sendToName server who (Tell localName msg)
  if ok then return ()
  else hPutStrLn clientHandle (who ++ " is not connected.")

sendToName :: Server -> CName -> Message -> STM Bool
sendToName server@Server{..} name msg = do
    clientmap <- readTVar clients
    case Map.lookup name clientmap of
        Nothing     -> return False
        Just client -> sendMessage server client msg >> return True

sendMessage :: Server -> Client -> Message -> STM ()
sendMessage _ (ClientLocal client) msg =
    sendLocal client msg
sendMessage server (ClientRemote client) msg =
    sendRemote server (clientHome client) (MsgSend (remoteName client) msg)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--            >> Decentralized Total-ordering Multicast <<
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

-- Proposer sends request
multicast :: Server -> ID -> String -> CName -> STM ()
multicast server@Server{..} msg uuid cname = do
  let pmsg = MulticastRequest spid msg uuid cname
  pids <- readTVar servers
  let v = 1 + length pids    -- number of votes needed from remote nodes
  -- update vote map
  voteMap <- readTVar votes
  writeTVar votes $ Map.insert uuid (v, 0) voteMap
  mapM_ (\pid -> sendRemote server pid pmsg) (spid : pids)

-- Receiver propose value to the Sender
multicast_propose :: Server -> ProcessId -> ID -> String -> CName -> STM ()
multicast_propose server@Server{..} pid uuid msg cname = do
  (p_val, a_val) <- readTVar counter
  let pval = 1 + max p_val a_val
  writeTVar counter (pval, a_val) -- update the largest number proposed
  messageMap <- readTVar messages
  let new_messageMap = Map.insert uuid (False, pval, pid, msg, cname) messageMap
  writeTVar messages new_messageMap
  sendRemote server pid $ MulticastPropose spid pval uuid

-- Proposer gets a propose response during the first request phase
multicast_accept :: Server -> Int -> String -> STM ()
multicast_accept server@Server{..} pval uuid = do -- update vote map
  voteMap <- readTVar votes
  case Map.lookup uuid voteMap of
    Just (c, m)  -> do
      let new_c = c - 1             -- new counter for the remaining votes
      let new_max = max pval m      -- the largest proposed value
      if new_c == 0 then do         -- all responses are collected
        -- delete the entry
        writeTVar votes $ Map.delete uuid voteMap
        multicast_decision server uuid new_max
      else do               -- still waiting for other responses
        (p_val, a_val) <- readTVar counter
        writeTVar counter (p_val, max new_max a_val)
        writeTVar votes $ Map.insert uuid (new_c, new_max) voteMap
    _ -> error "Should not reach here" >> return ()

-- Proposer makes the decision after collectioning all the responses
multicast_decision :: Server -> ID -> Int -> STM ()
multicast_decision server@Server{..} uuid m = do
  let pmsg = MulticastDeciscion spid m uuid
  pids <- readTVar servers
  mapM_ (\pid -> sendRemote server pid pmsg) (spid : pids)

-- Receiver receive a decision
multicast_agree :: Server -> ProcessId -> Int -> ID -> STM()
multicast_agree server@Server{..} _ m uuid = do
  messageMap <- readTVar messages
  case Map.lookup uuid messageMap of
    Just (False, _, pid, msg, cname) -> do
      (p_val, a_val) <- readTVar counter
      writeTVar counter (p_val, max a_val m)  -- update the largest number observed so far
      let new_messageMap = Map.insert uuid (True, m, pid, msg, cname) messageMap
      let list_ready = List.takeWhile (\(_, (f, _, _, _, _)) -> f) $ List.sortBy sortMessage (Map.toList new_messageMap)
      writeTVar messages new_messageMap
      foldl (\x (key, (flag, _, _, text, cn)) -> case flag of
          True  -> x >> multicast_deliver server text key cn
          False -> x >> return ()
        ) (return ()) list_ready
    _ -> error "Should not reach here" >> return ()

-- Sort the message buffer (process id is used to break the tie)
sortMessage :: (ID, (Bool, Int, ProcessId, String, CName)) ->
               (ID, (Bool, Int, ProcessId, String, CName)) -> Ordering
sortMessage (_, (_, a, b, _, _)) (_, (_, c, d, _, _))
  | a < c = LT
  | a > c = GT
  | otherwise = if b < d then LT else GT

-- The receiver deliver the message to the client. For now we just remove the other meta information
multicast_deliver :: Server -> String -> ID -> CName -> STM()
multicast_deliver server@Server{..} msg uuid cname = do
  messageMap <- readTVar messages
  writeTVar messages $ Map.delete uuid messageMap
  broadcastLocal server (Broadcast cname msg)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--                          >> MESSAGE Handling <<
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
db_get :: Server -> LocalClient -> Key -> STM()
db_get server@Server{..} LocalClient{..} k = do
  pids <- readTVar servers
  let pmsg = GetRequest k localName
  let allpids = List.sort (spid : pids)
  let db_pid = allpids !! (ord (head k) `mod` (length allpids))
  sendRemote server db_pid pmsg

db_set :: Server -> LocalClient -> Key -> Value -> STM()
db_set server@Server{..} LocalClient{..} k v = do
  pids <- readTVar servers
  let pmsg = SetRequest k v localName
  let allpids = List.sort (spid : pids)
  let db_pid = allpids !! (ord (head k) `mod` (length allpids))
  sendRemote server db_pid pmsg

dbstore_get :: Server -> Key -> CName -> STM()
dbstore_get server@Server{..} k name = do
  db <- readTVar mmdb
  let msg = case Map.lookup k db of
              Just v  -> DB $ "get() succeeds: " ++ k ++ " = " ++ v
              Nothing -> DB $ "get() failed: No such key: " ++ k
  void $ sendToName server name msg

dbstore_set :: Server -> Key -> Value -> CName -> STM ()
dbstore_set server@Server{..} k v name = do
  db <- readTVar mmdb
  writeTVar mmdb $ Map.insert k v db
  void $ sendToName server name $ DB ("set() succeeds: " ++ k ++ " = " ++ v)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--                          >> MESSAGE Handling <<
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

-- Handle message received from local client
handleMessage :: Server -> LocalClient -> Message -> IO Bool
handleMessage server@Server{..} client@LocalClient{..} message =
  case message of
    DB msg -> output msg
    Notice msg         -> output $ "*** " ++ msg
    Tell name msg      -> output $ "*" ++ name ++ "*: " ++ msg
    Broadcast name msg -> output $ "<" ++ name ++ ">: " ++ msg
    Command msg ->
      case words msg of
        ["/kick", who] -> do
            atomically $ kick server who localName
            return True
        "/tell" : who : what -> do
            tell server client who (unwords what)
            return True
        ["/quit"] ->
            return False
        "/broadcast" : what -> do
            atomically $ broadcast server $ Broadcast localName (unwords what)
            return True
        "/get" : key -> do
            atomically $ db_get server client (unwords key)
            return True
        "/set" : key : value -> do
            atomically $ db_set server client key (unwords value)
            return True
        ('/':_):_ -> do
            hPutStrLn clientHandle $ "Unrecognised command: " ++ msg
            return True
        _ -> do
          uuid <- genUUID
          putStrLn $ "Initiate a multicast (totally ordering) request: " ++ msg
          atomically $ multicast server msg uuid localName
          return True
  where output s = do hPutStrLn clientHandle s; return True

-- Handle message received from remote client
handleRemoteMessage :: Server -> PMessage -> Process ()
handleRemoteMessage server@Server{..} m =
  case m of
    MsgServerInfo rsvp rid pid cs -> newServerInfo server rsvp rid pid cs
    MsgBroadcast msg -> liftIO $ atomically $ broadcastLocal server msg
    MsgSend name msg -> liftIO $ atomically $ void $ sendToName server name msg
    MsgKick _ _   -> undefined
    MsgNewClient name pid -> liftIO $ atomically $ do
        ok <- checkAddClient server (ClientRemote (RemoteClient name pid))
        when (not ok) $ sendRemote server pid (MsgKick name "SYSTEM")
    MsgClientDisconnected name pid -> liftIO $ atomically $ do
         clientmap <- readTVar clients
         case Map.lookup name clientmap of
            Nothing -> return ()
            Just (ClientRemote (RemoteClient _ pid')) | pid == pid' ->
              deleteClient server name
            Just _ -> return ()
    -- Receive a request, need to queue the msg and propose a number
    MulticastRequest pid msg uuid cname -> liftIO $ do
      putStrLn (uuid ++ ": Receive MulticastRequest from " ++ show pid)
      atomically $ multicast_propose server pid uuid msg cname
    -- Send receive propose, need to identify which msg corresponds to it
    MulticastPropose _ pval uuid -> liftIO $ do
      putStrLn (uuid ++ ": Receive MulticastPropose value " ++ show pval)
      atomically $ do multicast_accept server pval uuid
    -- Receive the final decision for a message ordering
    MulticastDeciscion sender_pid timestamp uuid -> liftIO $ do
      putStrLn (uuid ++ ": Receive MulticastDeciscion from " ++ show sender_pid)
      atomically $ multicast_agree server sender_pid timestamp uuid
    -- Receive a set request
    SetRequest k v cn -> liftIO $ atomically $ dbstore_set server k v cn
    -- REceive a get reqeust
    GetRequest k cn -> liftIO $ atomically $ dbstore_get server k cn
    GetResponse _ _ -> undefined

-- Handle the join request by sending my self server information
handleWhereIsReply :: Server -> WhereIsReply -> Process ()
handleWhereIsReply _ (WhereIsReply _ Nothing) = return ()
handleWhereIsReply server@Server{..} (WhereIsReply _ (Just pid)) =
  liftIO $ atomically $ do
    clientmap <- readTVar clients
    sendRemote server pid
      (MsgServerInfo True ringId spid [ localName c | ClientLocal c <- Map.elems clientmap ])

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

-- Check if the client can successfully be added into local client list
checkAddClient :: Server -> Client -> STM Bool
checkAddClient server@Server{..} client = do
    clientmap <- readTVar clients
    let name = clientName client
    if Map.member name clientmap then return False
    else do writeTVar clients (Map.insert name client clientmap)
            broadcastLocal server $ Notice $ name ++ " has connected"
            return True

--
disconnectLocalClient :: Server -> CName -> IO ()
disconnectLocalClient server@Server{..} name = atomically $ do
     deleteClient server name
     sendRemoteAll server (MsgClientDisconnected name spid)

-- 
handleMonitorNotification :: Server -> ProcessMonitorNotification -> Process ()
handleMonitorNotification server@Server{..} (ProcessMonitorNotification _ pid _) = do
  say (printf "server on %s has died" (show pid))
  liftIO $ atomically $ do
    old_pids <- readTVar servers -- TODO
    writeTVar servers (filter (/= pid) old_pids)
    clientmap <- readTVar clients
    let
        now_disconnected (ClientRemote RemoteClient{..}) = clientHome == pid
        now_disconnected _ = False
        disconnected_clients = Map.filter now_disconnected clientmap
    writeTVar clients (Map.filter (not . now_disconnected) clientmap)
    mapM_ (deleteClient server) (Map.keys disconnected_clients)

--
newServerInfo :: Server -> Bool -> RId -> ProcessId -> [CName] -> Process ()
newServerInfo server@Server{..} rsvp rid pid remote_clients = do
  liftIO $ printf "%s received server info from %s [ring: %d]\n" (show spid) (show pid) rid
  join $ liftIO $ atomically $ do
    old_pids <- readTVar servers
    writeTVar servers (pid : filter (/= pid) old_pids)
    -- TODO: update peer list
    -- old_peers <- readTVar peers
    -- let new_peers = ((rid, pid) : filter (/= (rid, pid)) old_peers)
    -- writeTVar peers new_peers
    -- TODO: update chord finger table
    -- old_ftable <- readTVar ftable
    -- writeTVar ftable $ update_ftable new_peers old_ftable ring_id
    clientmap <- readTVar clients
    let new_clientmap = Map.union clientmap $ Map.fromList
               [ (n, ClientRemote (RemoteClient n pid)) | n <- remote_clients ]
            -- ToDo: should remove other remote clients with this pid
            -- ToDo: also deal with conflicts
    writeTVar clients new_clientmap
    when rsvp $ do
      sendRemote server pid
         (MsgServerInfo False ringId spid [ localName c | ClientLocal c <- Map.elems new_clientmap ])
    -- monitor the new server
    return (when (pid `notElem` old_pids) $ void $ monitor pid)


updateFtable :: [(RId, ProcessId)] -> Map RId (RId, ProcessId) -> RId -> Map RId (RId, ProcessId)
updateFtable = undefined

--
-- Sort the message buffer (process id is used to break the tie)
-- sortMessage :: (ID, (Bool, Int, ProcessId, String, CName)) ->
--                (ID, (Bool, Int, ProcessId, String, CName)) -> Ordering
-- sortMessage (_, (_, a, b, _, _)) (_, (_, c, d, _, _))
--   | a < c = LT
--   | a > c = GT
--   | otherwise = if b < d then LT else GT

deleteClient :: Server -> CName -> STM ()
deleteClient server@Server{..} name = do
    modifyTVar' clients $ Map.delete name
    broadcastLocal server $ Notice $ name ++ " has disconnected"

genUUID :: IO String
genUUID = do
    x <- U4.nextRandom
    return $ U.toString x

-- register remotable (using distributed-process framework)
remotable ['dNode]

rcdata :: RemoteTable -> RemoteTable
rcdata = Worker.__remoteTable
