{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE TemplateHaskell, DeriveDataTypeable, DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}

import Control.Concurrent.Classy

crefs = do
  r1 <- newCRef False
  r2 <- newCRef False
  x <- spawn $ writeCRef r1 True >> readCRef r2
  y <- spawn $ writeCRef r2 True >> readCRef r1
  (,) <$> readMVar x <*> readMVar y