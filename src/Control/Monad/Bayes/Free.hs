{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Control.Monad.Bayes.Free
-- Description : Free monad transformer over random sampling
-- Copyright   : (c) Adam Scibior, 2015-2020
-- License     : MIT
-- Maintainer  : leonhard.markert@tweag.io
-- Stability   : experimental
-- Portability : GHC
--
-- 'FreeSampler' is a free monad transformer over random sampling.
module Control.Monad.Bayes.Free
  -- ( FreeSampler,
  --   hoist,
  --   interpret,
  --   withRandomness,
  --   withPartialRandomness,
  --   runWith,
  -- )
where

import Control.Monad.Bayes.Class
import Control.Monad.State (evalStateT, get, put)
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.Trans.Free.Church (FT, MonadFree (..), hoistFT, iterT, iterTM, liftF)
import Control.Monad.Writer (WriterT (..), tell)
import Data.Functor.Identity (Identity, runIdentity)
import Data.Map
import Data.Text
import Control.Monad.State
import Control.Monad.Bayes.Sampler

-- | Random sampling functor.
newtype SamF a = Random (Double -> a)

instance Functor SamF where
  fmap f (Random k) = Random (f . k)

-- | Free monad transformer over random sampling.
--
-- Uses the Church-encoded version of the free monad for efficiency.
newtype FreeSampler m a = FreeSampler {runFreeSampler :: FT SamF m a}
  deriving newtype (Functor, Applicative, Monad, MonadTrans)

instance MonadFree SamF (FreeSampler m) where
  wrap = FreeSampler . wrap . fmap runFreeSampler

instance Monad m => MonadSample (FreeSampler m) where
  random = FreeSampler $ liftF (Random id)

-- | Hoist 'FreeSampler' through a monad transform.
hoist :: (Monad m, Monad n) => (forall x. m x -> n x) -> FreeSampler m a -> FreeSampler n a
hoist f (FreeSampler m) = FreeSampler (hoistFT f m)

-- | Execute random sampling in the transformed monad.
interpret :: MonadSample m => FreeSampler m a -> m a
interpret (FreeSampler m) = iterT f m
  where
    f (Random k) = random >>= k

-- | Execute computation with supplied values for random choices.
withRandomness :: Monad m => [Double] -> FreeSampler m a -> m a
withRandomness randomness (FreeSampler m) = evalStateT (iterTM f m) randomness
  where
    f (Random k) = do
      xs <- get
      case xs of
        [] -> error "FreeSampler: the list of randomness was too short"
        y : ys -> put ys >> k y

-- | Execute computation with supplied values for a subset of random choices.
-- Return the output value and a record of all random choices used, whether
-- taken as input or drawn using the transformed monad.
withPartialRandomness :: MonadSample m => [Double] -> FreeSampler m a -> m (a, [Double])
withPartialRandomness randomness (FreeSampler m) =
  runWriterT $ evalStateT (iterTM f $ hoistFT lift m) randomness
  where
    f (Random k) = do
      -- This block runs in StateT [Double] (WriterT [Double]) m.
      -- StateT propagates consumed randomness while WriterT records
      -- randomness used, whether old or new.
      xs <- get
      x <- case xs of
        [] -> random
        y : ys -> put ys >> return y
      tell [x]
      k x

-- | Like 'withPartialRandomness', but use an arbitrary sampling monad.
runWith :: MonadSample m => [Double] -> FreeSampler Identity a -> m (a, [Double])
runWith randomness m = withPartialRandomness randomness $ hoist (return . runIdentity) m


-- | For choice maps
withPartialRandomnessCM :: MonadSample m => Map Text Double -> FreeSampler (StateT Text m) a -> m (a, [Double])
withPartialRandomnessCM choicemap (FreeSampler m) = flip evalStateT "" $
  runWriterT $ (iterTM f m)
  where
    f (Random k) = do
      -- let (Random k, _) = _ $ evalStateT p -- evalStateT p ""
      -- This block runs in StateT [Double] (WriterT [Double]) m.
      -- StateT tracks the name of the variable while WriterT records
      -- random choices used, whether old or new.
      g <- get
      x <- case Data.Map.lookup g choicemap of
        Nothing -> random
        Just y -> return y -- y : ys -> put ys >> return y
      tell [x]
      k x

ex :: MonadSample m => FreeSampler (StateT Text m)  (Bool, Bool)
ex = do
  x <- lift (put ("x" :: Text)) >> bernoulli 0.5
  y <- lift (put ("y" :: Text)) >> bernoulli 0.5 <* lift (put ("" :: Text))
  z <- bernoulli 0.5
  return (x,y)

te = sampleIO $ withPartialRandomnessCM mp ex

mp = Data.Map.fromList [("y", 0.5), ("x", 0.8)]