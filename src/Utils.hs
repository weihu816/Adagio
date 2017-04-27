module Utils where

import qualified Data.UUID as U       -- UUID
import qualified Data.UUID.V4 as U4   -- UUID

genUUID :: IO String
genUUID = do
    x <- U4.nextRandom
    return $ U.toString x