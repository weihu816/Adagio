import AppServer
import Txn
import Test.HUnit
import Data.Word
import Utils
import Worker

main :: IO ()
main = do
  putStrLn "Unit Tests"
  runTestTT (TestList [testToTuple, testAddrStringToTuple, testBreakLine])
  return ()

testToTuple :: Test
testToTuple = "tuple" ~:
  TestList [ tupify4 ['a', 'b', 'c', 'd'] ~?= Just ('a', 'b', 'c', 'd'),
             tupify4 "wxyz" ~?= Just ('w', 'x', 'y', 'z'),
             tupify4 [0, 1, 2, 3] ~?= Just (0, 1, 2, 3),
             tupify4 [1, 2, 3] ~?= Nothing,
             tupify4 ([] :: [Int]) ~?= Nothing]

testAddrStringToTuple :: Test
testAddrStringToTuple = "address" ~:
  TestList 
    [ stringToAddrTuple "255.255.255.1" ~?= 
        Just (fromInteger 255, fromInteger 255, fromInteger 255, fromInteger 1), 
      stringToAddrTuple "255.255.255" ~?= Nothing,
      stringToAddrTuple "256.255.255.1" ~?=
        Just (fromInteger 0, fromInteger 255, fromInteger 255, fromInteger 1),
      stringToAddrTuple "255.255.255.-1" ~?= 
        Just (fromInteger 255, fromInteger 255, fromInteger 255, fromInteger 0)]

testBreakLine :: Test
testBreakLine = "multiline" ~:
  TestList [
    breakStringIntoLines "abc" 1 ~?= "a\nb\nc",
    breakStringIntoLines "abcde" 2 ~?= "ab\ncd\ne",
    breakStringIntoLines "" 3 ~?= "",
    breakStringIntoLines "abc" 0 ~?= "abc"]


fundsTransferTest :: Int -> Int -> IO ()
fundsTransferTest startingTotal accounts = do

  putStrLn "Step 1: Initializing accounts"
  txn1 <- beginTxn
  writeTxn txn1 "ROOT" "0"
  foldl (\x y -> x >> writeTxn txn1 ("CHILD" ++ show y) "0") (return ()) [0 .. (accounts - 1)]
  res1 <- commitTxn txn1
  putStrLn "Transaction 1 completed..."
  putStrLn "==========================================\n"


  putStrLn "Step 2: Distributing funds"
  txn2 <- beginTxn
  -- show root
  root <- readTxn txn2 "ROOT"
  putStrLn $ "ROOT = " ++ root
  -- Show children
  foldl (\x y -> x >> do
    child <- readTxn txn2 ("CHILD" ++ show y)
    putStrLn ("CHILD" ++ show y ++ " = " ++ child))
    (return ()) [0 .. (accounts - 1)]
  let fundsPerChild = (read root :: Int) `quot` accounts
  -- distribute funds to root
  foldl (\x y -> x >> writeTxn txn2 ("CHILD" ++ show y) (show fundsPerChild))
    (return ()) [0 .. (accounts - 1)]
  -- update root
  writeTxn txn2 "ROOT" $ show $ (read root :: Int) - fundsPerChild * accounts
  res2 <- commitTxn txn2
  putStrLn "Transaction 2 completed..."
  putStrLn "==========================================\n"

  return ()