import AppServer
import Txn
import Test.HUnit
import Data.Word
import Test.QuickCheck
import Test.QuickCheck.Monadic
import Utils
import Worker

main :: IO ()
main = do
  putStrLn "Unit Tests"
  runTestTT (TestList [testToTuple, testAddrStringToTuple, testBreakLine])
  putStrLn "QuickCheck Properties"
  quickCheckN 500 prop_uuid
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

quickCheckN :: Test.QuickCheck.Testable prop => Int -> prop -> IO ()
quickCheckN n = quickCheckWith $ stdArgs { maxSuccess = n }

prop_uuid :: Property
prop_uuid = monadicIO $ do
  id1 <- run genUUID
  id2 <- run genUUID

  Test.QuickCheck.Monadic.assert (id1 /= id2)