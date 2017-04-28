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
import qualified Data.Set as Set
import Data.Map (Map)
import Data.List.Split (splitOn)
import qualified Data.List as List
import Control.Exception
import Data.Char
import KVStore
import Utils
import Data.Tuple.Select

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
    forM_ peers $ \peer -> whereisRemoteAsync peer "dNode"
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
    t <- newTVarIO Map.empty
    tv <- newTVarIO Map.empty
    return Server { clients = c, servers = s, proxychan = o, spid = pid,
                    peers = p, ftable = f, ringSize = rsize, ringId = rid,
                    counter = x, votes = v, messages = m, mmdb = d,
                    txns = t, txnVotes = tv}

--------------------------------------------------------------------------------

-- The listener in the forked thread
socketListener :: Server -> Int -> IO ()
socketListener server port = withSocketsDo $ do
  sock <- listenOn (PortNumber (fromIntegral port))
  printf "Listening on port %d\n" port
  forever $ do (h, addr, p) <- accept sock
               printf "Accepted connection from %s: %s\n" addr (show p)
               forkFinally (registerClient server h) (\_ -> hClose h)

-- Read the client identifier (unique)
registerClient :: Server -> Handle -> IO ()
registerClient server@Server{..} h = do
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
kick server@Server{..} who by = do
  clientmap <- readTVar clients
  case Map.lookup who clientmap of
    Nothing -> void $ sendToName server by (Notice $ who ++ " is not connected")
    Just (ClientLocal v) -> do writeTVar (clientKicked v) $ Just ("by "++by)
                               void $ sendToName server by (Notice $ "you kicked "++who)
    Just (ClientRemote v) -> sendRemote server (clientHome v) (MsgKick who by)

tell :: Server -> LocalClient -> CName -> String -> IO ()
tell server@Server{..} LocalClient{..} who msg = do
  ok <- atomically $ sendToName server who (Tell localName msg)
  unless ok $ hPutStrLn clientHandle (who ++ " is not connected.")

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
multicastPropose :: Server -> ProcessId -> ID -> String -> CName -> STM ()
multicastPropose server@Server{..} pid uuid msg cname = do
  (p_val, a_val) <- readTVar counter
  let pval = 1 + max p_val a_val
  writeTVar counter (pval, a_val) -- update the largest number proposed
  messageMap <- readTVar messages
  let new_messageMap = Map.insert uuid (False, pval, pid, msg, cname) messageMap
  writeTVar messages new_messageMap
  sendRemote server pid $ MulticastPropose spid pval uuid

-- Proposer gets a propose response during the first request phase
multicastAccept :: Server -> Int -> String -> STM ()
multicastAccept server@Server{..} pval uuid = do -- update vote map
  voteMap <- readTVar votes
  case Map.lookup uuid voteMap of
    Just (c, m)  -> do
      let new_c = c - 1             -- new counter for the remaining votes
      let new_max = max pval m      -- the largest proposed value
      if new_c == 0 then do         -- all responses are collected
        writeTVar votes $ Map.delete uuid voteMap -- delete the entry
        multicastDecision server uuid new_max
      else do                       -- still waiting for other responses
        (p_val, a_val) <- readTVar counter
        writeTVar counter (p_val, max new_max a_val)
        writeTVar votes $ Map.insert uuid (new_c, new_max) voteMap
    _ -> return ()

-- Proposer makes the decision after collectioning all the responses
multicastDecision :: Server -> ID -> Int -> STM ()
multicastDecision server@Server{..} uuid m = do
  let pmsg = MulticastDeciscion spid m uuid
  pids <- readTVar servers
  mapM_ (\pid -> sendRemote server pid pmsg) (spid : pids)

-- Receiver receive a decision
multicastAgree :: Server -> ProcessId -> Int -> ID -> STM()
multicastAgree server@Server{..} _ m uuid = do
  messageMap <- readTVar messages
  case Map.lookup uuid messageMap of
    Just (False, _, pid, msg, cname) -> do
      (p_val, a_val) <- readTVar counter
      writeTVar counter (p_val, max a_val m)  -- update the largest number observed so far
      let new_messageMap = Map.insert uuid (True, m, pid, msg, cname) messageMap
      let list_ready = List.takeWhile (\(_, (f, _, _, _, _)) -> f) $ List.sortBy sortMessage (Map.toList new_messageMap)
      writeTVar messages new_messageMap
      foldl (\x (key, (flag, _, _, text, cn)) ->
        if flag then x >> multicastDeliver server text key cn else void x)
        (return ()) list_ready
    _ -> return ()

-- Sort the message buffer (process id is used to break the tie)
sortMessage :: (ID, (Bool, Int, ProcessId, String, CName)) ->
               (ID, (Bool, Int, ProcessId, String, CName)) -> Ordering
sortMessage (_, (_, a, b, _, _)) (_, (_, c, d, _, _))
  | a < c = LT
  | a > c = GT
  | otherwise = if b < d then LT else GT

-- The receiver deliver the message to the client. For now we just remove the other meta information
multicastDeliver :: Server -> String -> ID -> CName -> STM()
multicastDeliver server@Server{..} msg uuid cname = do
  messageMap <- readTVar messages
  writeTVar messages $ Map.delete uuid messageMap
  broadcastLocal server (Broadcast cname msg)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--                          >> Database Messaging <<
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- In memory database operations
dbSend :: Server -> KVKey -> PMessage -> STM ()
dbSend server@Server{..} k pmsg = do
  pids <- readTVar servers
  let allpids = List.sort (spid : pids)
  let db_pid = allpids !! (ord (head k) `mod` length allpids)
  sendRemote server db_pid pmsg

dbWeakGet :: Server -> LocalClient -> KVKey -> STM()
dbWeakGet server@Server{..} LocalClient{..} k =
  dbSend server k $ GetRequest k localName False

dbWeakSet :: Server -> LocalClient -> KVKey -> KVVal -> STM()
dbWeakSet server@Server{..} LocalClient{..} k v =
  dbSend server k $ SetRequest k v localName

dbstoreGet :: Server -> KVKey -> CName -> Bool -> STM()
dbstoreGet server@Server{..} k name b = do
  db <- readTVar mmdb
  let msg = case Map.lookup k db of
              Just (v, v')  -> if b then DB (v ++ " " ++ (show v')) 
                               else DB v
              Nothing -> DB ""
  void $ sendToName server name msg

dbstoreSet :: Server -> KVKey -> KVVal -> CName -> STM ()
dbstoreSet server@Server{..} k v name = do
  db <- readTVar mmdb
  case Map.lookup k db of
    Nothing -> writeTVar mmdb $ Map.insert k (v, 1) db
    Just (_, ver) -> writeTVar mmdb $ Map.insert k (v, ver) db
  void $ sendToName server name $ DB v

-- Database Two Phase Transaction with Optimistic Concurrency Control
dbRead :: Server -> LocalClient -> KVKey -> STM ()
dbRead server@Server{..} LocalClient{..} k =
  dbSend server k $ GetRequest k localName True

dbCommit :: Server -> LocalClient -> String -> [String] -> CName -> STM ()
dbCommit server@Server{..} LocalClient{..} txnId str cname = do
  let l = map ((\[x, y, z] -> (x, y, read z :: Int)) . splitOn "#") str
      l' = List.groupBy (\(x, _, _) (y, _, _) -> x == y) l
      l'' = map (\x -> (sel1 (head x), KVRequest spid txnId x)) l'
  vMap <- readTVar txnVotes
  cnt <- foldl (\x (k, pmsg) -> do c <- x; dbSend server k pmsg; return (c + 1)) (return 0) l''
  writeTVar txnVotes $ Map.insert txnId (cnt, Set.empty, TXN_UNDECIDED, cname) vMap

dbVote :: Server -> ProcessId -> TxnId -> [(KVKey, KVVal, KVVersion)] -> STM ()
dbVote server@Server{..} pid txnId options = do
  recs <- readTVar txns
  unless (Map.member txnId recs) $
    writeTVar txns (Map.insert txnId (TXN_UNDECIDED, False, []) recs)
  r <- foldl (\b (key, val, ver) -> do
    res <- b
    if not res then return False
    else do
      records <- readTVar txns
      case Map.lookup txnId records of
        Just (stat, dirty, l) -> do
          db <- readTVar mmdb
          case Map.lookup key db of
            Just (val', ver') ->
              if (ver' > ver) then do sendAbort; return False
              else do
                writeTVar mmdb (Map.insert key (val', ver+1) db)
                writeTVar txns (Map.insert txnId (stat, dirty, (key, val, ver+1):l) records); return True
            Nothing -> do writeTVar txns (Map.insert txnId (stat, dirty, (key, val, ver+1):l) records); return True
        _ -> error "dVote should not reach here" >> return False
    ) (return True) options
  when r sendReady; return ()
  where sendAbort = sendRemote server pid $ KVResponse spid txnId VoteAbort
        sendReady = sendRemote server pid $ KVResponse spid txnId VoteReady

dbAccept :: Server -> ProcessId -> TxnId -> KVVote -> STM ()
dbAccept server@Server{..} apid txnId vote = do
  vMap <- readTVar txnVotes
  case Map.lookup txnId vMap of
    Just (c, ps, TXN_UNDECIDED, cname) ->
      if vote == VoteReady then
        if c - 1 == 0 then do -- commit now!
          writeTVar txnVotes $ Map.insert txnId (c - 1, Set.insert apid ps, TXN_COMMITTED, cname) vMap
          let pmsg = KVResult spid txnId DecisionCommit
          mapM_ (\pid -> sendRemote server pid pmsg) (Set.insert apid ps)
        else writeTVar txnVotes $ Map.insert txnId (c - 1, Set.insert apid ps, TXN_UNDECIDED, cname) vMap
      else do -- abourt now!
        writeTVar txnVotes $ Map.insert txnId (c - 1, Set.insert apid ps, TXN_ABORTED, cname) vMap
        let pmsg = KVResult spid txnId DecisionAbort
        mapM_ (\pid -> sendRemote server pid pmsg) (Set.insert apid ps)
    _ -> return ()

dbDecide :: Server -> ProcessId -> TxnId -> KVDecision -> STM ()
dbDecide server@Server{..} pid txnId decision = do
  records <- readTVar txns
  case Map.lookup txnId records of
    Just (TXN_UNDECIDED, dirty, options) -> do
      if decision == DecisionCommit then do
        foldl (\b (key, val, ver) -> b >> do
            db <- readTVar mmdb
            case Map.lookup key db of
              Just (_, ver') ->
                when (ver >= ver') $ writeTVar mmdb (Map.insert key (val, ver) db)
              _ -> writeTVar mmdb (Map.insert key (val, ver) db)
          ) (return ()) options
        writeTVar txns (Map.insert txnId (TXN_COMMITTED, dirty, options) records)
      else writeTVar txns (Map.insert txnId (TXN_ABORTED, dirty, options) records)
      sendRemote server pid $ KVACK spid txnId
    _ -> error "dbDecide should not reach here" >> return ()


dbDone :: Server -> ProcessId -> TxnId -> STM ()
dbDone server@Server{..} pid txnId = do
  vMap <- readTVar txnVotes
  case Map.lookup txnId vMap of
    Just (c, ps, stat, cname) -> do
      let new_ps = Set.delete pid ps
      writeTVar txnVotes $ Map.insert txnId (c, new_ps, stat, cname) vMap
      when (Set.null new_ps) $
        if stat == TXN_COMMITTED then void $ sendToName server cname (DB "OK")
        else void $ sendToName server cname (DB "ABORT")
    _ -> error "dbDone should not reach here" >> return ()


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
    Command msg ->
      case words msg of
        ["/echo", what] -> output $ "echo <" ++ what ++ ">"
        ["/kick", who] -> do
            atomically $ kick server who localName; return True
        "/tell" : who : what -> do
            tell server client who (unwords what); return True
        ["/quit"] -> return False
        ["/broadcast", what] -> do
            atomically $ broadcast server $ Broadcast localName what
            return True
        ["/get", key] -> do
            atomically $ dbWeakGet server client key; return True
        "/set" : key : value -> do
            atomically $ dbWeakSet server client key (unwords value); return True
        ["/read", key] -> do
            atomically $ dbRead server client key; return True
        "/commit" : txnId : str -> do
            putStrLn $ "Receve a transaction: " ++ txnId ++ " " ++ (unwords str)
            atomically $ dbCommit server client txnId str localName; return True
        ('/':_):_ -> do
            hPutStrLn clientHandle $ "Unrecognised command: " ++ msg; return True
        _ -> do
          uuid <- genUUID
          putStrLn $ "Initiate a multicast (totally ordering) request: " ++ msg
          atomically $ multicast server msg uuid localName
          return True
    DB msg -> output msg
    Notice msg         -> output $ "*** " ++ msg
    Tell name msg      -> output $ "*" ++ name ++ "*: " ++ msg
    Broadcast name msg -> output $ "<" ++ name ++ ">: " ++ msg
  where output s = do hPutStrLn clientHandle s; return True

-- Handle message received from remote client
handleRemoteMessage :: Server -> PMessage -> Process ()
handleRemoteMessage server@Server{..} m =
  case m of
    MsgServerInfo rsvp rid pid cs -> newServerInfo server rsvp rid pid cs
    MsgBroadcast msg -> liftIO $ atomically $ broadcastLocal server msg
    MsgSend name msg -> liftIO $ atomically $ void $ sendToName server name msg
    MsgKick who by   -> liftIO $ atomically $ kick server who by
    MsgNewClient name pid -> liftIO $ atomically $ do
        ok <- checkAddClient server (ClientRemote (RemoteClient name pid))
        unless ok $ sendRemote server pid (MsgKick name "SYSTEM")
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
      atomically $ multicastPropose server pid uuid msg cname
    -- Send receive propose, need to identify which msg corresponds to it
    MulticastPropose _ pval uuid -> liftIO $ do
      putStrLn (uuid ++ ": Receive MulticastPropose value " ++ show pval)
      atomically $ multicastAccept server pval uuid
    -- Receive the final decision for a message ordering
    MulticastDeciscion sender_pid timestamp uuid -> liftIO $ do
      putStrLn (uuid ++ ": Receive MulticastDeciscion from " ++ show sender_pid)
      atomically $ multicastAgree server sender_pid timestamp uuid
    -- Receive a set request
    SetRequest k v cn -> liftIO $ atomically $ dbstoreSet server k v cn
    -- REceive a get reqeust
    GetRequest k cn b -> liftIO $ atomically $ dbstoreGet server k cn b
    KVRequest pid txnId options -> liftIO $ do
      putStrLn (txnId ++ ": Receive KVRequest " ++ show options)
      atomically $ dbVote server pid txnId options
    KVResponse pid txnId vote -> liftIO $ do
      putStrLn (txnId ++ ": Receive KVResponse from " ++ show pid)
      atomically $ dbAccept server pid txnId vote
    KVResult pid txnId decision -> liftIO $ do
      putStrLn (txnId ++ ": Receive KVResult from " ++ show pid)
      records <- atomically $ readTVar txns
      case Map.lookup txnId records of
        Just (x, _, z) -> do putStrLn (show x); putStrLn (show z)
        _ -> return ()
      atomically $ dbDecide server pid txnId decision
    KVACK pid txnId -> liftIO $ do
      putStrLn (txnId ++ ": Receive KVACK from " ++ show pid)
      atomically $ dbDone server pid txnId

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
            case name of 
              '/':_  -> return True
              _ -> do broadcastLocal server $ Notice $ name ++ " has connected"
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
    when rsvp $ sendRemote server pid
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
    case name of 
      '/':_  -> return ()
      _ -> broadcastLocal server $ Notice $ name ++ " has disconnected"


-- register remotable (using distributed-process framework)
remotable ['dNode]

rcdata :: RemoteTable -> RemoteTable
rcdata = Worker.__remoteTable
