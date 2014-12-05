{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable, DeriveFunctor, DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
-- | DNA monad and actor creation and communication primitives.
--
--   Actors track list of nodes they own and monitor their immediate
--   children. We also have to impose important limitation: children
--   cannot outlive their parents. It's quite reasonable to allow it
--   but at the same time it could lead to processes which hangs
--   around forever because no one will request their result. We need
--   some kind of distributed garbage collection to reap such
--   processes.
--
--   When spawned process\/group of processes returns handle for
--   obtaining result of their computation. It could be serialized and
--   send to other processes.
module DNA.DNA (
      -- * DNA monad
      DNA(..)
    , runDNA
    , GroupID
    , liftP
    , getMonitor
      -- * Promises
    , Promise(..)
    , await
    , Group(..)
    , gather
      -- * Scattering
    , Scatter
    , runScatter
    , same
    , scatter
      -- * Spawning of actors
    , Actor(..)
    , actor
    , runActor
    , spawnActor
    , eval
    , forkLocal
    , forkRemote
    , forkGroup
    , forkGroupFailout
      -- * CH
    , __remoteTable
    ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Control.Monad.IO.Class
import Control.Distributed.Static (closureApply)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import qualified Control.Distributed.Process.Platform.UnsafePrimitives as Unsafe
import Control.Distributed.Process.Serializable (Serializable)

import Data.Binary   (Binary)
import Data.Typeable (Typeable)
import GHC.Generics  (Generic)

import DNA.Types
import DNA.Monitor


----------------------------------------------------------------
-- Monad for building programs and data types
----------------------------------------------------------------

-- | Monad for defining DNA programs. Actors could spawn other
--   actors. One important limitation is that actors cannot outlive
--   their parent. Otherwise we could have processes whose results
--   will be never requested and no way to reap such deadlocked
--   processes.
--
--   Every actor owns set of nodes on which it could spawn other actors.
--   Upon completion this set of nodes is returned to parent actor.
newtype DNA a = DNA (ReaderT Monitor Process a)
                deriving (Functor,Applicative,Monad,MonadIO)

-- | Execute DNA program
runDNA :: Monitor -> DNA a -> Process a
runDNA mon (DNA dna)
    = flip runReaderT mon dna

-- | Lift 'Process' computation to DNA monad
liftP :: Process a -> DNA a
liftP = DNA . lift

-- | Get monitor process
getMonitor :: DNA Monitor
getMonitor = DNA ask



----------------------------------------------------------------
-- Promises
----------------------------------------------------------------

-- | Handle for obtaining result from process. Such handles are
--   returned by fork* functions. Handles from child processes must
--   not be returned from the parent process
--
--   FIXME: If we await more than once then second call will block
--          indefinitely wihout any way to detect deadlock. Since
--          promises are serailizable we can obtain such deadlocks
--          between different processes.
data Promise a = Promise Monitor ProcessId (SendPort (SendPort a))
                 deriving (Typeable,Generic)

instance (Typeable a, Binary a) => Binary (Promise a)


-- | Await result from promise. Function will block.
--
--   This function will as well receive messages about termination of
--   monitored processes.
await :: Serializable a => Promise a -> DNA a
await (Promise mon pid ch) = do
    chFail <- liftP $ waitForProcess mon pid
    -- Send channel for sending result to remote process
    liftP $ do (chSend,chRecv) <- newChan
               sendChan ch chSend
               receiveWait [ matchChan chRecv return
                           , matchChan chFail $ \_ -> error "OOPS!"
                           ]


----------------------------------------------------------------
-- Groups
----------------------------------------------------------------

-- | Set of values which is produces by group of processes which
--   execute same code.
data Group a = Group
    Monitor
    GroupID
    -- ID of group
    Int
    -- Number of elements. Could be different from length of worker processes
    [SendPort (SendPort a)]
    -- Port to send destinations to
    deriving (Typeable,Generic)

instance (Typeable a, Binary a) => Binary (Group a)


-- | Gather all results from child processes.
gather :: (Serializable a) => Group a -> (a -> a -> a) -> a -> DNA a
gather (Group mon gid n remotes) op x0 = do
    chFail <- liftP $ waitForGroup mon gid
    -- Send channels to all workers in thread
    (chSend,chRecv) <- liftP newChan
    liftP $ forM_ remotes $ \ch -> sendChan ch chSend
    -- Merge results
    let loop 0 a0 = return a0
        loop i a0 = receiveWait
            [ matchChan chRecv $ \a -> loop (i-1) (op a0 a)
            , matchChan chFail $ \m -> case m of
                  Nothing -> error "Ooops!"
                  Just  k -> loop (i-k) a0
            ]
    liftP $ loop n x0



----------------------------------------------------------------
-- Scattering values to children
----------------------------------------------------------------

-- | Very important question is how to pass parameters to multiple
--   childs. We have two primary way to divide data.
--
--    1. Divide data on parent processa nd send values to childs.
--
--    2. Let childs to select suitable part of data by themselves
--       using their rank.
--
--   We provide applicative interface for data splitting. It's a bit
--   awkward to use. Ideally we'd want to use idiom bracket but
--   upcoming applicative-do in GHC 7.10 will be useful as well.
data Scatter a
    = Same a
    | Scatter (Int -> [a])
    deriving (Functor)

instance Applicative Scatter where
    pure = same
    Same    f <*> Same a    = Same (f a)
    Same    f <*> Scatter a = Scatter $ (fmap . fmap) f a
    Scatter f <*> Same a    = Scatter $ (fmap . fmap) ($ a) f
    Scatter f <*> Scatter a = Scatter $ \n -> zipWith ($) (f n) (a n)

runScatter :: Int -> Scatter a -> [a]
runScatter n (Same a) = replicate n a
runScatter n (Scatter f)
    | length xs == n = xs
    | otherwise      = error "runScatter: list length doesn't match!"
  where xs = f n


-- | Send same value to all nodes.
same :: a -> Scatter a
same = Same

-- | Scatter value
scatter :: (Int -> a -> [b]) -> a -> Scatter b
scatter f a = Scatter (\n -> f n a)



----------------------------------------------------------------
-- Spawning of actors
----------------------------------------------------------------

-- | Actor which receive messages of type @a@ and produce result of
--   type @b@. It's phantom-typed and could only be constructed by
--   'actor' which ensures that types are indeed correct.
data Actor a b where
    Actor :: (Serializable a, Serializable b) => (a -> DNA b) -> Actor a b
    deriving (Typeable)


-- | Smart constructor for actors. Here we receive parameters and
--   output channel for an actor
actor :: (Serializable a, Serializable b)
      => (a -> DNA b)
      -> Actor a b
actor = Actor

-- | Start actor execution on remote node. Here we obtain all
--   parameters from messages
runActor :: Actor a b -> Process ()
runActor (Actor fun) = do
    -- Get list of nodes and spawn local monitor
    nodes <- expect
    mon   <- runMonitor nodes
    -- Create channel for obtaining channel to return results and send
    -- it to process requesting them
    Parent pid      <- expect
    (chSend,chRecv) <- newChan
    send pid chSend
    -- Obtain parameter and evaluate action
    Param a <- expect
    b       <- runDNA mon (fun a)
    dest    <- receiveChan chRecv
    sendChan dest b
    -- Make sure that process will not terminate before we start
    -- monitoring it
    Completed <- expect
    return ()


-- | Send to actor necessary parameters
sendToActor :: (Serializable a, Serializable b)
            => [NodeId] -> a -> ProcessId -> DNA (SendPort (SendPort b))
sendToActor nodes a pid = liftP $ do
    me <- getSelfPid
    send pid nodes
    send pid (Parent me)
    send pid (Param a)
    -- FIXME: deadlock. Process can die before it responds!
    expect

remotable [ 'runActor ]


-- | Spawn actor on remote node and set up monitoring.
spawnActor :: (Typeable a, Typeable b)
           => NodeId -> Closure (Actor a b) -> Process ProcessId
spawnActor nid child = do
    spawn nid $ $(mkStaticClosure 'runActor) `closureApply` child

-- | Evaluate actor in the same thread
eval :: (Serializable a, Serializable b)
     => Actor a b
     -> a
     -> DNA b
eval (Actor act) a = act a


-- | Fork process on local node
forkLocal :: (Serializable a, Serializable b)
          => NodePool           -- ^ List of nodes process allowed to use
          -> Actor a b          -- ^ Actor
          -> a                  -- ^ Parameters for an actor
          -> DNA (Promise b)
forkLocal pool child a = do
    mon <- getMonitor
    (aid,nodes) <- liftP $ askNodePool mon pool
    pid         <- liftP $ spawnLocal $ runActor child
    ch          <- sendToActor nodes a pid
    liftP $ registerWorker mon aid pid
    return $ Promise mon pid ch

-- | Fork process on remote node
forkRemote :: (Serializable a, Serializable b)
           => ReqNode              -- ^ List of nodes process allowed to use
           -> Closure (Actor a b)  -- ^ Actor
           -> a                    -- ^ Parameters for an actor
           -> DNA (Promise b)
forkRemote req child a = do
    mon <- getMonitor
    (aid,Nodes nid nodes) <- liftP $ askSingleNode mon req
    pid <- liftP $ spawnActor nid child
    liftP $ registerWorker mon aid pid
    ch  <- sendToActor nodes a pid
    return $ Promise mon pid ch


-- | Create group of nodes
--
--   FIXME: at the moment child processes are not allowed to spawn
--          code on remote nodes.
forkGroup
    :: (Serializable a, Serializable b)
    => ReqGroup                 -- ^ List of nodes to spawn on
    -> Closure (Actor a b)      -- ^ Actor
    -> Scatter a                -- ^ Parameters to actors.
    -> DNA (Group b)
forkGroup req child scat = do
    -- Get schedule for list of nodes
    mon <- getMonitor
    (gid,nodes) <- liftP $ askNodeGroup mon req
    let n  = length nodes
        xs = runScatter n scat
    -- Spawn group of processes and register them
    pids <- forM (nodes `zip` xs) $ \(Nodes nid nids, a) -> do
        p  <- liftP $ spawnActor nid child
        ch <- sendToActor nids a p
        return (p,ch)
    liftP $ registerGroup mon gid (fst <$> pids)
    return $ Group mon gid n (snd <$> pids)


-- | Create group of nodes and allow failout
--
--   FIXME: at the moment child processes are not allowed to spawn
--          code on remote nodes.
forkGroupFailout
    :: (Serializable a, Serializable b)
    => ReqGroup                 -- ^ List of nodes to spawn on
    -> Closure (Actor a b)      -- ^ Actor
    -> Scatter a                -- ^ Parameters to actors.
    -> DNA (Group b)
forkGroupFailout req child scat = do
    -- Get schedule for list of nodes
    mon <- getMonitor
    (gid,nodes) <- liftP $ askNodeGroup mon req
    let n  = length nodes
        xs = runScatter n scat
    -- Spawn group of processes and register them
    pids <- forM (nodes `zip` xs) $ \(Nodes nid nids, a) -> do
        p  <- liftP $ spawnActor nid child
        ch <- sendToActor nids a p
        return (p,ch)
    liftP $ registerGroup mon gid (fst <$> pids)
    return $ Group mon gid n (snd <$> pids)