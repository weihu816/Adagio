module Utils where

import qualified Data.UUID as U       -- UUID
import qualified Data.UUID.V4 as U4   -- UUID
import Data.Word
import Data.List.Split
import Data.Time
import System.Socket
import System.Socket.Family.Inet
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP

genUUID :: IO String
genUUID = do
    x <- U4.nextRandom
    return $ U.toString x

-- | Check whether a string starts with a certain prefix
startsWith' :: String -> String -> Bool
startsWith' _ [] = True
startsWith' [] _ = False
startsWith' (x:xs) (y:ys) 
  | x == y  = startsWith' xs ys
  | otherwise = False

-- | Utility function for ClientUI, decide how many lines will a string be split
getLineNumber :: String -> Int -> Int
getLineNumber str col = case col of
                          0 -> 3
                          _ -> quot (length str) col + 3

-- | convert list of 4 elements to tuple
-- return tuple of 4 0's when number of elements is not 4
tupify4 :: [a] -> Maybe (a, a, a, a)  
tupify4 [w, x, y, z] = Just (w, x, y, z)
tupify4 _            = Nothing

-- | convert string of address to tuple of 8-bit unsigned integer type
stringToAddrTuple :: String -> Maybe (Word8, Word8, Word8, Word8)
stringToAddrTuple str = let segs = splitOn "." str in -- assume valid input here
  tupify4
    (foldr
       (\ x res ->
          let num = read x :: Integer in
            if num > 0 && num <= 255 then fromInteger num : res else 0 : res)
       []
       segs)

-- | create a socket and connect to it by remote IP address and port
constructSocket :: InetAddress -> InetPort -> IO (Socket Inet Stream TCP)
constructSocket addr port = do
  sock <- socket :: IO (Socket Inet Stream TCP)
  setSocketOption sock (ReuseAddress True)
  return sock

-- | get zoned time IO string
getTimeStringIO :: IO String
getTimeStringIO = do 
  t <- getZonedTime
  let timeStr = formatTime defaultTimeLocale "%T, %F (%Z)" t
  return timeStr

-- | break long string into several lines based on column number
breakStringIntoLines :: String -> Int -> String
breakStringIntoLines str 0 = str
breakStringIntoLines str n = 
  aux str n 0 0 "" where
    aux str col cnt idx res
      | length str == cnt = res
      | idx == col = aux str col cnt 0 (res ++ "\n")
      | otherwise = aux str col (cnt + 1) (idx + 1) (res ++ [str !! cnt])