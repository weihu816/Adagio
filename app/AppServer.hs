{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import System.Environment
import Node (rcdata)

main :: IO()
main = do
 [port] <- getArgs
 let rtable = rcdata initRemoteTable
 backend <- initializeBackend "localhost" port rtable
 startMaster backend appserver

appserver :: [NodeId] -> Process ()
appserver peers0 = do
    mynode <- getSelfNode
    let peers = filter (/= mynode) peers0
    say ("peers are " ++ show peers)