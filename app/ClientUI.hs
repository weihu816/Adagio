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
  , clickable
  , withDefAttr
  , padLeftRight
  , padTopBottom
  , padBottom
  )
import Brick.Util (on)
import Brick.BChan

import System.Socket
import System.Socket.Family.Inet
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP
import System.Environment

import Client

newtype CustomEvent = Recv String deriving Show

data Name = VP1
          | Edit1
          | Button1
          deriving (Ord, Show, Eq)

data St =
    St { _clicked :: [T.Extent Name]
       , _focusRing :: F.FocusRing Name
       , _edit1 :: E.Editor String Name
       , _sock :: Socket Inet Stream TCP
       , _serverAddr :: InetAddress
       , _serverPort :: InetPort
       , _clockIO :: IO String
       , _messageList :: [String]
       , _content :: String
       , _viewportWidth :: Int
       , _lastClick :: Maybe (Name, T.Location)}

makeLenses ''St

drawUI :: St -> [T.Widget Name]
drawUI st = [ui]
    where
        scrollArea = viewport VP1 Vertical $
                       vBox (str <$> st^.messageList)

        e1 = F.withFocusRing (st^.focusRing) E.renderEditor (st^.edit1)

        b1 = let wasClicked = (fst <$> st^.lastClick) == Just Button1
             in clickable Button1 $
               withDefAttr "send_button" $
               B.border $
               padTopBottom 1 $
               padLeftRight (if wasClicked then 1 else 3) $
               str (if wasClicked then ">>" <> "Send" <> "<<" else "Send")

        ui = C.center $ B.borderWithLabel (str "Messages") $  -- hLimit 60 $ vLimit 21 $
             vBox [ scrollArea, B.hBorder, hBox [vLimit 9 e1 <+> padLeftRight 1
                    (padTopBottom 2 $ vLimit 5 $ hLimit 20 $ C.vCenter b1)]]

vp1Scroll :: M.ViewportScroll Name
vp1Scroll = M.viewportScroll VP1

appEvent :: St -> T.BrickEvent Name CustomEvent -> T.EventM Name (T.Next St)
appEvent st (T.MouseDown n _ _ loc)           = processButton st n loc
appEvent st T.MouseUp{}                       = M.continue $ st & lastClick .~ Nothing
appEvent st (T.VtyEvent V.EvMouseUp{})        = M.continue $ st & lastClick .~ Nothing
appEvent st (T.VtyEvent (V.EvKey V.KDown [])) = M.vScrollBy vp1Scroll 1 >> M.continue st
appEvent st (T.VtyEvent (V.EvKey V.KUp []))   = M.vScrollBy vp1Scroll (-1) >> M.continue st
appEvent st (T.VtyEvent ev)                   =
    case ev of
        V.EvKey V.KEsc []        -> M.halt st
        V.EvKey V.KEnter []      -> processEditor st
        _                        -> M.continue =<< 
                                      case F.focusGetCurrent (st^.focusRing) of
                                        Just Edit1 -> T.handleEventLensed st 
                                                        edit1 E.handleEditorEvent ev
                                        Nothing    -> return st
appEvent st (T.AppEvent (Recv msg))           = processViewport st msg

--appEvent st _                                 = M.continue st

-- | modify contents in viewport, modify visible parts of viewport
processViewport :: St -> String -> T.EventM Name (T.Next St)
processViewport st msg = 
  liftIO getTimeStringIO >>= \timeStr -> 
    M.vScrollBy vp1Scroll (getLineNumber msg 80) >>
      M.continue
        (st & clockIO .~ getTimeStringIO & messageList %~
           (++ [timeStr ++ "\n" ++ breakStringIntoLines msg 80 ++ "\n"]))

-- | when send button is clicked, send msg and clear input text box 
processButton :: St -> Name -> T.Location -> T.EventM Name (T.Next St)
processButton st n loc = 
  case n of 
    Button1 -> do
                 let buffer = unlines (E.getEditContents $ st^.edit1)
                 if length buffer > 1 then 
                     liftIO (sendMsgToServer buffer st) >> 
                       if startsWith' buffer "/quit" then M.halt st
                       else M.continue $ st & lastClick .~ Just (n, loc)
                                            & edit1 %~ E.applyEdit killToBOL
                                            & content .~ buffer
                 else 
                   M.continue $ st & lastClick .~ Just (n, loc)
    _       -> M.continue st

-- | read user input from edit area and send to remote server
processEditor :: St -> T.EventM Name (T.Next St)
processEditor st = do
  let buffer = unlines (E.getEditContents $ st^.edit1)
  if length buffer > 1 then 
    liftIO (sendMsgToServer buffer st) >> 
      if startsWith' buffer "/quit" then M.halt st
      else 
        M.continue $ st & edit1 %~ E.applyEdit killToBOL & content .~ buffer
  else 
    M.continue st

-- | send input string to remote server based on fields in state
sendMsgToServer :: String -> St -> IO St
sendMsgToServer msg st = do 
  let f = SocketAddressInet (st^.serverAddr) (st^.serverPort) :: SocketAddress Inet
  let socket = st^.sock
  _ <- sendTo socket (pack msg) mempty f
  return st

-- | initialize all fields in state
initialState :: Socket Inet Stream TCP -> InetAddress -> InetPort -> St
initialState sock addr port =
    St []
       (F.focusRing [Edit1])
       (E.editor Edit1 (str . unlines) Nothing "")
       sock
       addr
       port
       getTimeStringIO
       []
       ""
       0
       Nothing

-- | Attribute map for this application
theMap :: A.AttrMap
theMap = A.attrMap V.defAttr
    [ (E.editAttr,        V.white `on` V.blue)
    , (E.editFocusedAttr, V.black `on` V.cyan)
    , ("send_button",     V.white `on` V.green)
    ]

-- | Cursor focus
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

-- | Thread used to receive incoming messages
-- When there is message available at socket, write to BChan and trigger
-- Brick custom event
recvThread :: Socket Inet Stream TCP -> BChan CustomEvent -> IO ()
recvThread sock chan = do
    bs <- receive sock 1024 mempty
    writeBChan chan $ Recv (unpack bs)

-- | get to run when invalid ip address is provided
addressExit :: String -> IO ()
addressExit addr = 
  putStrLn $ "Invalid IP address format" ++ addr

main :: IO ()
main = do
  let buildVty = do
          v <- V.mkVty =<< V.standardIOConfig
          V.setMode (V.outputIface v) V.Mouse True
          return v

  [addr, port] <- getArgs
  let serverPort' = read port :: Integer
  if serverPort' < 0 || serverPort' > 65536
    then putStrLn $ "Invalid port number" ++ port
  else 
    let serverPort = fromInteger serverPort' in
    let tempAddr = stringToAddrTuple addr in
    case tempAddr of 
      Nothing          -> addressExit addr
      Just serverAddr' -> do
        let serverAddr = inetAddressFromTuple serverAddr'
        chan <- newBChan 10
        sock <- constructSocket serverAddr serverPort
        let f = SocketAddressInet serverAddr serverPort :: SocketAddress Inet
        connect sock f

        forkIO $ forever $ 
          recvThread sock chan

        finalState <- M.customMain buildVty (Just chan) theApp 
                      (initialState sock serverAddr serverPort)

        close sock

        return ()