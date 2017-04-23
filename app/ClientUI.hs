{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
module Main where

import Lens.Micro
import Lens.Micro.TH
import qualified Graphics.Vty as V

import Data.Monoid ((<>))
import Data.Text.Zipper (killToBOL)
import Data.ByteString.Char8 (unpack, pack)
import Data.Word
import Data.Time
import Data.List.Split

import Control.Monad (void, forever)
import Control.Concurrent (threadDelay, forkIO)
import Control.Monad.IO.Class

import qualified Brick.Main as M
import qualified Brick.Types as T
import qualified Brick.Widgets.Border as B
import qualified Brick.Widgets.Center as C
import qualified Brick.Widgets.Edit as E
import qualified Brick.AttrMap as A
import qualified Brick.Focus as F
import Brick.Types
  ( Widget
  , ViewportType (Horizontal, Vertical, Both)
  )
import Brick.Widgets.Core
  ( (<+>)
  , (<=>)
  , hLimit
  , vLimit
  , str
  , hBox
  , vBox
  , viewport
  , str
  )
import Brick.Util (on)
import Brick.BChan

import System.Socket
import System.Socket.Family.Inet
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP
import System.Environment

data CustomEvent = Recv String
                 deriving Show

data Name = Edit1 
          | VP1 
          deriving (Ord, Show, Eq)

data St =
    St { _focusRing :: F.FocusRing Name
       , _edit1 :: E.Editor String Name
       , _sock :: Socket Inet Stream TCP
       , _serverAddr :: InetAddress
       , _serverPort :: InetPort
       , _clockIO :: IO String
       , _messageList :: [String]
       , _content :: String
       , _viewportWidth :: Int}

makeLenses ''St

drawUI :: St -> [T.Widget Name]
drawUI st = [ui]
    where
        e1 = F.withFocusRing (st^.focusRing) E.renderEditor (st^.edit1)

        ui = C.center $ B.border $ -- hLimit 60 $ vLimit 21 $
             vBox [ scrollArea, vLimit 10 $ e1]

        scrollArea = viewport VP1 Vertical $
                       vBox $ (str <$> st^.messageList)

vp1Scroll :: M.ViewportScroll Name
vp1Scroll = M.viewportScroll VP1

appEvent :: St -> T.BrickEvent Name CustomEvent -> T.EventM Name (T.Next St)
appEvent st (T.VtyEvent (V.EvKey V.KDown [])) = M.vScrollBy vp1Scroll 1 >> M.continue st
appEvent st (T.VtyEvent (V.EvKey V.KUp []))   = M.vScrollBy vp1Scroll (-1) >> M.continue st
appEvent st (T.AppEvent (Recv msg))           = processViewport st msg                              
appEvent st (T.VtyEvent ev)                   =
    case ev of
        V.EvKey V.KEsc []        -> M.halt st
        V.EvKey V.KEnter []      -> processEditor st
        _                        -> M.continue =<< case F.focusGetCurrent (st^.focusRing) of
                                                     Just Edit1 -> T.handleEventLensed st edit1 E.handleEditorEvent ev
                                                     Nothing -> return st
appEvent st _                                 = M.continue st

getLineNumber :: String -> Int -> Int
getLineNumber str col = case col of
                          0 -> 3
                          _ -> (quot (length str) col) + 3

breakStringIntoLines :: String -> Int -> String
breakStringIntoLines str n = 
  aux str n 0 0 "" where
    aux str col cnt idx res = if length str == cnt then res
                              else if idx == col then aux str col cnt 0 (res ++ "\n")
                                   else aux str col (cnt + 1) (idx + 1) (res ++ [str !! cnt])

processViewport :: St -> String -> T.EventM Name (T.Next St)
processViewport st msg = do
  liftIO (getTimeStringIO) >>= \timeStr -> M.vScrollBy vp1Scroll (getLineNumber msg 80) >> (M.continue $ 
                              st & clockIO .~ getTimeStringIO
                                 & messageList %~ (++ [timeStr ++ "\n" ++ 
                                                  (breakStringIntoLines msg 80) ++ "\n"]))

processEditor :: St -> T.EventM Name (T.Next St)
processEditor st = do
  let buffer = unlines (E.getEditContents $ st^.edit1)
  liftIO (do sendMsgToServer buffer st) >>
    (M.continue $ st & edit1 %~ E.applyEdit killToBOL & content .~ buffer)

sendMsgToServer :: String -> St -> IO St
sendMsgToServer msg st = do 
  let f = SocketAddressInet inetLoopback (st^.serverPort) :: SocketAddress Inet
  let socket = st^.sock
  _ <- sendTo socket (pack msg) mempty f
  return st

initialState :: (Socket Inet Stream TCP) -> InetAddress -> InetPort -> St
initialState sock addr port =
    St (F.focusRing [Edit1])
       (E.editor Edit1 (str . unlines) Nothing "")
       (sock)
       (addr)
       (port)
       (getTimeStringIO)
       ([])
       ("")
       (0)

getTimeStringIO :: IO String
getTimeStringIO = do 
  t <- getZonedTime
  let timeStr = formatTime defaultTimeLocale "%T, %F (%Z)" t
  return timeStr


constructSocket :: InetPort -> IO (Socket Inet Stream TCP)
constructSocket port = do
  sock <- socket :: IO (Socket Inet Stream TCP)
  setSocketOption sock (ReuseAddress True)
  let f = SocketAddressInet inetLoopback port :: SocketAddress Inet
  connect sock f
  return sock

theMap :: A.AttrMap
theMap = A.attrMap V.defAttr
    [ (E.editAttr,        V.white `on` V.blue)
    , (E.editFocusedAttr, V.black `on` V.cyan)
    ]

appCursor :: St -> [T.CursorLocation Name] -> Maybe (T.CursorLocation Name)
appCursor = F.focusRingCursor (^.focusRing)

theApp :: M.App St CustomEvent Name
theApp =
    M.App { M.appDraw = drawUI
          , M.appChooseCursor = appCursor
          , M.appHandleEvent = appEvent
          , M.appStartEvent = return
          , M.appAttrMap = const theMap
          }

recvThread :: (Socket Inet Stream TCP) -> BChan CustomEvent -> IO ()
recvThread sock chan = do
    bs <- receive sock 1024 mempty
    writeBChan chan $ Recv (unpack bs)

stringToAddrTuple :: String -> (Word8, Word8, Word8, Word8)
stringToAddrTuple str = let segs = splitOn "." str in  -- assume valid input here
  tupify4 $ (foldr (\x res -> (fromInteger (read x :: Integer)) : res) [] segs)

tupify4 :: [a] -> (a, a, a, a)  
tupify4 [w, x, y, z] = (w, x, y, z)

main :: IO ()
main = do

  [addr, port] <- getArgs
  let serverPort = fromInteger (read port :: Integer)
  let serverAddr = inetAddressFromTuple $ stringToAddrTuple addr
  chan <- newBChan 10
  sock <- constructSocket serverPort

  forkIO $ forever $ 
    recvThread sock chan

  finalState <- M.customMain (V.mkVty V.defaultConfig) (Just chan) theApp (initialState sock serverAddr serverPort)

  return ()