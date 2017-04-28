import Control.Monad
import Control.Concurrent
import System.IO
import Text.Printf
import Control.Exception
import Control.Concurrent.Async
import Control.Concurrent.STM
import ConcurrentUtils (forkFinally)
import Data.ByteString.Char8 (unpack, pack)
import System.Socket
import System.Socket.Family.Inet
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP
import System.Environment

workerList :: [InetPort]
workerList = [8080, 8081, 8082]

-- <<main
main = do
  [workerIndex] <- getArgs
  let myIndex = read workerIndex :: Int
  sock <- socket :: IO (Socket Inet Stream TCP)
  setSocketOption sock (ReuseAddress True)
  bind sock (SocketAddressInet inetAny (workerList !! myIndex))
  listen sock 2
  printf "Listening on index %d\n" myIndex
  factor <- atomically $ newTVar 2
  forkIO $ talk2 factor
  forever $ do
    conn@(s, f) <- accept sock
    printf "Accepted connection\n"
    forkFinally (talk conn factor) (\_ -> close s)
-- >>

-- <<talk
talk :: Family f => (Socket f t p, SocketAddress f) -> TVar Integer -> IO ()
talk conn@(s, f) factor = do
  bs <- receive s 1024 mempty
  putStrLn $ unpack bs

talk2 :: TVar Integer -> IO ()
talk2 factor = do
  c <- atomically newTChan
  race (server factor c) (receiveX c)
  return ()
-- >>

-- <<receive
receiveX :: TChan String -> IO ()
receiveX c = forever $ do
  line <- getLine
  atomically $ writeTChan c line
-- >>

-- <<server
server :: TVar Integer -> TChan String -> IO ()
server factor c = forever $ do
  l <- atomically $ readTChan c
  foldl (\x y -> x >> ( do
      let f = SocketAddressInet inetLoopback y :: SocketAddress Inet
      sock <- socket :: IO (Socket Inet Stream TCP)
      connect sock f
      _ <- sendTo sock (pack l) mempty f
      return ())
    ) (return ()) workerList
  
-- >>