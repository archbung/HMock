{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Demo where

import Control.Exception (Exception)
import Control.Monad (unless, when)
import Control.Monad.Catch (MonadMask, catch, finally, throwM)
import Data.Char (isLetter)
import Test.HMock
  ( Mockable (..),
    anything,
    allowUnexpected,
    expect,
    expectAny,
    makeMockable,
    makeMockableBase,
    runMockT,
    (|->),
    (|=>),
  )
import Test.Hspec (SpecWith, describe, example, it)
import Prelude hiding (appendFile, readFile, writeFile)

-- This is an in-depth example of using HMock to test a system with dependencies
-- on external systems.  The application here is a chat bot, which needs to
-- be able to talk to services for authentication, communication, and storage.

-------------------------------------------------------------------------------
-- PART 1: TYPES AND CLASSES

-- We start with some basic types.

-- | Represents a user in the system.
newtype User = User String deriving (Eq, Show)

-- | Represents a permission level.  The Guest level is given to users who are
-- not logged in.  NormalUser requires being logged in.  Admin requires being
-- logged in with elevated permissions.
data PermLevel = Guest | NormalUser | Admin deriving (Eq, Show)

-- | Represents a chat room.
newtype Room = Room String deriving (Eq, Show)

-- HMock needs MTL-style type classes to mock.  Here, we implement a number of
-- these classes.

-- | An MTL-style type class to capture authentication.  This can be used in two
-- ways.
--
-- 1. Using the 'login' and 'logout' actions to start and end an authenticated
--    session.  While the user is logged in, 'getUser' and 'hasPermission' will
--    return appropriate responses for that user.  Remember to log out!
--
-- 2. Using the 'withLogin' action to run an action as a user.  The user will
--    be logged out automatically when the action finishes.
class Monad m => MonadAuth m where
  login :: String -> String -> m ()
  logout :: m ()
  hasPermission :: PermLevel -> m Bool

-- | An MTL-style type class for sending and receiving chat messages.  We can
-- start and close sessions, send messages, poll for messages (blocking for a
-- period of time if desired), and ban other users (probably only if we're an
-- admin!)
class MonadAuth m => MonadChat m where
  joinRoom :: String -> m Room
  leaveRoom :: Room -> m ()
  sendChat :: Room -> String -> m ()
  pollChat :: Room -> m (User, String)
  ban :: Room -> User -> m ()

-- | An MTL-style type class for accessing the filesystem.  It wouldn't be a
-- good idea to write mock-style tests for all uses of the filesystem, but we
-- can use HMock to set up a lightweight fake.
class Monad m => MonadBugReport m where
  reportBug :: String -> m ()

-- | An exception thrown when a banned user attempts to join a room.
data BannedException = BannedException deriving (Show)

instance Exception BannedException

-------------------------------------------------------------------------------
-- PART 2: IMPLEMENTATION

-- We will now implement a simple chatbot, which joins a chat room and responds
-- to messages.

type MonadChatBot m = (MonadChat m, MonadBugReport m)

chatbot :: (MonadMask m, MonadChatBot m) => String -> m ()
chatbot roomName = do
  login "HMockBot" "secretish"
  handleRoom roomName `finally` logout

handleRoom :: (MonadMask m, MonadChatBot m) => String -> m ()
handleRoom roomName = do
  room <- joinRoom roomName
  listenAndReply room `finally` leaveRoom room

listenAndReply :: MonadChatBot m => Room -> m ()
listenAndReply room = do
  (user, msg) <- pollChat room
  finished <- case words msg of
    ["!leave"] -> return True
    ("!bug" : ws) -> reportBug (unwords ws) >> return False
    ws | any isFourLetterWord ws -> banIfAdmin room user >> return False
    _ -> return False
  unless finished (listenAndReply room)

isFourLetterWord :: [Char] -> Bool
isFourLetterWord = (== 4) . length . filter isLetter

sendBugReport :: MonadChatBot m => Room -> String -> m ()
sendBugReport room bug = do
  reportBug bug
  sendChat room "Thanks for the bug report!"

banIfAdmin :: MonadChat m => Room -> User -> m ()
banIfAdmin room user = do
  isAdmin <- hasPermission Admin
  when isAdmin $ do
    ban room user
    sendChat room "Sorry for the disturbance!"

-------------------------------------------------------------------------------
-- PART 3: MOCKS

-- Set up the mocks for the three classes.  makeMockable is the first step to
-- using HMock, and defines a number of boilerplate types and instances that are
-- used by the framework and your tests.
--
-- How we do this depends on whether there is setup we want to package with the
-- class:

-- Since there is no setup for MonadBugReport, it's easiest to use makeMockable
-- to derive all instances needed to mock this class.
makeMockable ''MonadBugReport

-- For MonadAuth and MonadChat, we have default behaviors we'd like to offer
-- to all tests.  So instead of makeMockable, we use makeMockableBase to derive
-- MockableBase, which contains all the boilerplate.  We can then write a
-- Mockable instance with setup steps.

makeMockableBase ''MonadAuth

instance Mockable MonadAuth where
  setupMockable _ = do
    -- Ensure that when the chatbot logs in with the right username and
    -- password.
    allowUnexpected $
      Login "HMockBot" "secretish"
        |=> \_ -> do
          -- Every login should be accompanied by a logout
          expect Logout

    -- By default, assume that the bot has all permissions.  Individual tests
    -- can override this assumption.
    allowUnexpected $ HasPermission_ anything |-> True

makeMockableBase ''MonadChat

instance Mockable MonadChat where
  setupMockable _ = do
    allowUnexpected $
      JoinRoom_ anything
        |=> \(JoinRoom room) -> do
          -- The bot should leave every room it joins.
          expect $ LeaveRoom (Room room)
          return (Room room)

    -- Our tests aren't generally concerned with what the bot says.  Individual
    -- tests can add expectations to check for specific messages.
    allowUnexpected $ SendChat_ anything anything |-> ()

-------------------------------------------------------------------------------
-- PART 4: TESTS

-- We're now ready to write tests for the behavior of our chat bot.  We'll just
-- write a few representative tests to see how things work.  I'm using Hspec for
-- the test framework, but you can use your favorite framework.

demoSpec :: SpecWith ()
demoSpec = describe "chatbot" $ do
  it "bans users who use four-letter words" $
    example $
      runMockT $ do
        -- Set up some chat messages to be received.
        expectAny $
          PollChat_ anything
            |-> (User "A", "I love Haskell")
            |-> (User "B", "Lovin' the ass. candies")
            |-> (User "B", "!leave")

        -- User A should be banned for using a four-letter word ("love").  User
        -- B should not be banned for using an abbreviation for "assorted."
        expect $ Ban (Room "#haskell") (User "A")

        -- Finally, run the system under test.
        chatbot "#haskell"

  it "still logs out cleanly when there are errors" $ do
    example $
      runMockT $ do
        expectAny $ JoinRoom "#haskell" |=> \_ -> throwM BannedException

        -- An exception will be thrown when attempting to read chat.  The bot
        -- is still expected to log out.
        chatbot "#haskell" `catch` \BannedException -> return ()

  it "doesn't ban if it doesn't have permission" $ do
    example $
      runMockT $ do
        -- Override the earlier default behavior, returning False for the Admin
        -- permission level.
        expectAny $ HasPermission Admin |-> False
        expectAny $
          PollChat_ anything
            |-> (User "A", "I love Haskell")
            |-> (User "A", "!leave")

        chatbot "#haskell"

  it "doesn't ban people for using four-letter words in bug reports" $ do
    example $
      runMockT $ do
        -- A four letter word is used in a bug report.  This is understandable,
        -- so the user shouldn't be banned.  The bug should be reported,
        -- instead.
        expectAny $
          PollChat_ anything
            |-> (User "A", "!bug Fix the damn website!")
            |-> (User "A", "!leave")
        expect $ ReportBug "Fix the damn website!"

        chatbot "#haskell"
