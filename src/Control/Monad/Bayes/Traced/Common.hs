-- |
-- Module      : Control.Monad.Bayes.Traced.Common
-- Description : Numeric code for Trace MCMC
-- Copyright   : (c) Adam Scibior, 2015-2020
-- License     : MIT
-- Maintainer  : leonhard.markert@tweag.io
-- Stability   : experimental
-- Portability : GHC
module Control.Monad.Bayes.Traced.Common
  ( Trace(Trace, variables, output, density),
    singleton,
    output,
    scored,
    bind,
    mhTrans,
    mhTransWithBool,
    mhTrans',
    burnIn,
  )
where

import Control.Monad.Bayes.Class
    ( discrete, MonadSample(bernoulli, random) )
import Control.Monad.Bayes.Free as FreeSampler
    ( hoist, withPartialRandomness, FreeSampler )
import Control.Monad.Bayes.Weighted as Weighted
    ( hoist, runWeighted, Weighted )
import Control.Monad.Trans.Writer ( WriterT(WriterT, runWriterT) )
import Data.Functor.Identity ( Identity(runIdentity) )
import Numeric.Log (Log, ln)
import Statistics.Distribution.DiscreteUniform (discreteUniformAB)
import Debug.Trace (traceM, trace)

-- | Collection of random variables sampled during the program's execution.
data Trace a = Trace
  { -- | Sequence of random variables sampled during the program's execution.
    variables :: [Double],
    --
    output :: a,
    -- | The probability of observing this particular sequence.
    density :: Log Double
  }

instance Functor Trace where
  fmap f t = t {output = f (output t)}

instance Applicative Trace where
  pure x = Trace {variables = [], output = x, density = 1}
  tf <*> tx =
    Trace
      { variables = variables tf ++ variables tx,
        output = output tf (output tx),
        density = density tf * density tx
      }

instance Monad Trace where
  t >>= f =
    let t' = f (output t)
     in t' {variables = variables t ++ variables t', density = density t * density t'}

singleton :: Double -> Trace Double
singleton u = Trace {variables = [u], output = u, density = 1}

scored :: Log Double -> Trace ()
scored w = Trace {variables = [], output = (), density = w}

bind :: Monad m => m (Trace a) -> (a -> m (Trace b)) -> m (Trace b)
bind dx f = do
  t1 <- dx
  t2 <- f (output t1)
  return $ t2 {variables = variables t1 ++ variables t2, density = density t1 * density t2}

-- | A single Metropolis-corrected transition of single-site Trace MCMC.
mhTrans :: MonadSample m => Weighted (FreeSampler m) a -> Trace a -> m (Trace a)
mhTrans m t = fst <$> mhTransWithBool m t

-- | A single Metropolis-corrected transition of single-site Trace MCMC.
mhTransWithBool :: MonadSample m => Weighted (FreeSampler m) a -> Trace a -> m (Trace a, Bool)
mhTransWithBool m t@Trace {variables = us, density = p} = do
  let n = length us
  us' <- do
    i <- discrete $ discreteUniformAB 0 (n - 1)
    u' <- random
    case splitAt i us of
      (xs, _ : ys) -> return $ xs ++ (u' : ys)
      _ -> error "impossible"
  ((b, q), vs) <- runWriterT $ runWeighted $ Weighted.hoist (WriterT . withPartialRandomness us') m
  let ratio = (exp . ln) $ min 1 (q * fromIntegral n / (p * fromIntegral (length vs)))
  -- error $ show q
  accept <- bernoulli ratio
  -- if not accept then error $ show ratio else return ()
  return $ if accept then (Trace vs b q, True) else (t, False)

-- | A variant of 'mhTrans' with an external sampling monad.
mhTrans' :: MonadSample m => Weighted (FreeSampler Identity) a -> Trace a -> m (Trace a)
mhTrans' m = mhTrans (Weighted.hoist (FreeSampler.hoist (return . runIdentity)) m)

-- | burn in an MCMC chain for n steps (which amounts to dropping samples of the end of the list)
burnIn :: Int -> [a] -> [a]
burnIn n ls = let len = length ls in take (len - n) ls
