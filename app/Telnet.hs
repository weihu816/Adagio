import Control.Concurrent (forkIO, killThread)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Resource
import Data.Conduit
import Data.Conduit.Binary
import Network (connectTo, PortID (..))
import System.Environment (getArgs, getProgName)
import System.IO


main :: IO ()
main = do
    args <- getArgs
    case args of
        [host, port] -> client host (read port :: Int)
        _ -> return () -- ignore

client :: String -> Int -> IO ()
client host port = runResourceT $ do
    (releaseSock, hsock) <- allocate (connectTo host $ PortNumber $ fromIntegral port) hClose
    liftIO $ Prelude.mapM_ (`hSetBuffering` LineBuffering) [ stdin, stdout, hsock ]
    (releaseThread, _) <- allocate (forkIO $ runResourceT $ sourceHandle stdin $$ sinkHandle hsock) killThread
    sourceHandle hsock $$ sinkHandle stdout
    release releaseThread
    release releaseSock