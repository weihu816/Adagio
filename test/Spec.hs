import AppServer
import Txn

main :: IO ()
main = fundsTransferTest 1000 1


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
