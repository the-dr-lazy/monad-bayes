{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wall #-}

-- |
-- Module      : Control.Monad.Bayes.Sampler
-- Description : Pseudo-random sampling monads
-- Copyright   : (c) Adam Scibior, 2015-2020
-- License     : MIT
-- Maintainer  : leonhard.markert@tweag.io
-- Stability   : experimental
-- Portability : GHC
--
-- 'SamplerIO' and 'SamplerST' are instances of 'MonadSample'. Apply a 'MonadCond'
-- transformer to obtain a 'MonadInfer' that can execute probabilistic models.
module Control.Monad.Bayes.Sampler
  ( Sampler,
    sampleIOfixed,
    sampleWith,
    sampleSTfixed,
    toBins,
    sampleMean,
  )
where

import Control.Foldl qualified as F hiding (random)
import Control.Monad.Bayes.Class
  ( MonadSample
      ( bernoulli,
        beta,
        categorical,
        gamma,
        geometric,
        normal,
        random,
        uniform
      ),
  )
import Control.Monad.ST (ST)
import Control.Monad.Trans.Reader (ReaderT (..), runReaderT)
import Data.Fixed (mod')
import Numeric.Log (Log (..))
import System.Random.MWC.Distributions qualified as MWC
import System.Random.Stateful (IOGenM, STGenM, StatefulGen, StdGen, mkStdGen, newIOGenM, newSTGenM, uniformDouble01M, uniformRM)

newtype Sampler g m a = Sampler (StatefulGen g m => ReaderT g m a)

instance Functor (Sampler g m) where
  fmap f (Sampler s) = Sampler $ fmap f s

instance Applicative (Sampler g m) where
  pure x = Sampler $ pure x
  (Sampler f) <*> (Sampler x) = Sampler $ f <*> x

runSampler :: StatefulGen g m => Sampler g m a -> ReaderT g m a
runSampler (Sampler s) = s

instance Monad (Sampler g m) where
  (Sampler x) >>= f = Sampler $ x >>= runSampler . f

-- For convenience
sampleIOfixed :: Sampler (IOGenM StdGen) IO a -> IO a
sampleIOfixed x = newIOGenM (mkStdGen 1729) >>= sampleWith x

sampleWith :: (StatefulGen r m) => Sampler r m a -> r -> m a
sampleWith (Sampler m) = runReaderT m

instance MonadSample (Sampler g m) where
  random = Sampler (ReaderT uniformDouble01M)

  uniform a b = Sampler (ReaderT $ uniformRM (a, b))
  normal m s = Sampler (ReaderT (MWC.normal m s))
  gamma shape scale = Sampler (ReaderT $ MWC.gamma shape scale)
  beta a b = Sampler (ReaderT $ MWC.beta a b)

  bernoulli p = Sampler (ReaderT $ MWC.bernoulli p)
  categorical ps = Sampler (ReaderT $ MWC.categorical ps)
  geometric p = Sampler (ReaderT $ MWC.geometric0 p)

-- | Run the sampler with a fixed random seed.
sampleSTfixed :: Sampler (STGenM StdGen s) (ST s) b -> ST s b
sampleSTfixed x = do
  gen <- newSTGenM (mkStdGen 1729)
  sampleWith x gen

type Bin = (Double, Double)

-- | binning function. Useful when you want to return the bin that
-- a random variable falls into, so that you can show a histogram of samples
toBin ::
  -- | bin size
  Double ->
  -- | number
  Double ->
  Bin
toBin binSize n = let lb = n `mod'` binSize in (n - lb, n - lb + binSize)

toBins :: Double -> [Double] -> [Double]
toBins binWidth = fmap (fst . toBin binWidth)

sampleMean :: [(Double, Log Double)] -> Double
sampleMean samples =
  let z = F.premap (ln . exp . snd) F.sum
      w = (F.premap (\(x, y) -> x * ln (exp y)) F.sum)
      s = (/) <$> w <*> z
   in F.fold s samples
