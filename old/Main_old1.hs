-- Main.hs, final code
module Main where
 
import System.Socket
import System.Socket.Family.Inet
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP
import Data.ByteString.Char8 (unpack, pack)
import Control.Exception
import Control.Concurrent
import Control.Monad (when, void)
import Control.Monad.Fix (fix)
import Data.List.Split (splitOn)
import Data.Char (isSpace)

main :: IO ()
main = do
  sock <- socket :: IO (Socket Inet Stream TCP)
  setSocketOption sock (ReuseAddress True)
  bind sock (SocketAddressInet inetAny 8080)
  listen sock 2
  chan <- newChan
  forkIO $ fix $ \loop -> do
    (_, msg) <- readChan chan
    loop
  mainLoop sock chan 0
 
type Msg = (Int, String)
 
mainLoop :: Family f => Socket f t p -> Chan Msg -> Int -> IO ()
mainLoop sock chan msgNum = do
  conn <- accept sock
  _ <- forkIO (runConn conn chan msgNum)
  mainLoop sock chan $! msgNum + 1

trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace

runConn :: Family f => (Socket f t p, SocketAddress f) -> Chan Msg -> Int -> IO ()
runConn (sock, f) chan msgNum = do
    let broadcast msg = writeChan chan (msgNum, msg)
    _ <- sendTo sock (pack "Hi, what's your name?\n") mempty f
    bs <- receive sock 1024 mempty
    putStrLn $ unpack bs
    let name = trim (unpack bs)
    broadcast ("--> " ++ name ++ " entered chat.\n")
    _ <- sendTo sock (pack ("Welcome, " ++ name ++ "!\n")) mempty f
 
    commLine <- dupChan chan
    
    m <- newEmptyMVar
    putMVar m 'x'

    -- fork off a thread for reading from the duplicated channel
    reader <- forkIO $ fix $ \loop -> do
        (nextNum, line) <- readChan commLine
        when (msgNum /= nextNum) (sendAux (filter (not . null) (splitOn "\n" line)) sock f)
        loop
 
    handle (\(SomeException _) -> return 0) $ fix $ \loop -> do
        bs' <- receive sock 1024 mempty
        let line = filter (not . null) (splitOn "\n" (trim (unpack bs')))
        case line of
             -- If an exception is caught, send a message and break the loop
             ("quit":_) -> sendTo sock (pack "Bye!\n") mempty f
             -- else, continue looping.
             _      -> foldl (\y x -> y >> broadcast (name ++ ": " ++ x ++ "\n")) (return ()) line >> loop
 
    killThread reader                      -- kill after the loop ends
    broadcast ("<-- " ++ name ++ " left.\n") -- make a final broadcast
    close sock

sendAux :: Family f => [String] -> Socket f t p -> SocketAddress f -> IO ()
sendAux [] _ _ = return ()
sendAux (x:xs) sock f = do
  void (sendTo sock (pack (x ++ "\n")) mempty f)
  sendAux xs sock f


