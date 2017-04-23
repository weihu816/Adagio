{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE TemplateHaskell, DeriveDataTypeable, DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Node as Node hiding (newLocalNode)
import System.Environment             -- getArgs
import Worker

-- Main
main :: IO()
main = do
 [port, d_port, ring_size, ring_id] <- getArgs
 backend <- initializeBackend "localhost" port (Worker.rcdata initRemoteTable)
 node <- newLocalNode backend
 Node.runProcess node (Worker.master backend d_port ring_size ring_id)
