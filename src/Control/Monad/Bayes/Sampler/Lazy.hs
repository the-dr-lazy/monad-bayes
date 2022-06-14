{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | This is a port of the implementation of LazyPPL: https://lazyppl.bitbucket.io/
module Control.Monad.Bayes.Sampler.Lazy where

import Control.Monad
-- import Control.Monad.Extra

-- import Control.DeepSeq
-- import Control.Exception (evaluate)

-- import System.IO.Unsafe

-- import GHC.Exts.Heap
-- import System.Mem
-- import Unsafe.Coerce

import Control.Monad.Bayes.Class (MonadInfer, MonadSample (normal, random), condition)
import Control.Monad.Bayes.Weighted (Weighted, runWeighted)
import Control.Monad.Extra (iterateM)
import Control.Monad.State.Lazy (State, get, put, runState)
import Numeric.Log (Log (..))
import System.Random
  ( Random (randoms),
    RandomGen (split),
    getStdGen,
    newStdGen,
  )
import qualified System.Random as R

-- | This module defines
--    1. A monad 'Sampler'
--    2. the inference method 'lwis' (likelihood weighted importance sampling)
--    3. 'mh' (Metropolis-Hastings algorithm based on lazily mutating parts of the tree at random)

-- | A 'Tree' is a lazy, infinitely wide and infinitely deep tree, labelled by Doubles
-- | Our source of randomness will be a Tree, populated by uniform [0,1] choices for each label.
-- | Often people just use a list or stream instead of a tree.
-- | But a tree allows us to be lazy about how far we are going all the time.
data Tree = Tree Double [Tree]

-- | A probability distribution over a is
-- | a function 'Tree -> a'
-- | The idea is that it uses up bits of the tree as it runs
newtype Sampler a = Sampler {runSampler :: Tree -> a}

-- | Two key things to do with trees:
-- | Split tree splits a tree in two (bijectively)
-- | Get the label at the head of the tree and discard the rest
splitTree :: Tree -> (Tree, Tree)
splitTree (Tree r (t : ts)) = (t, Tree r ts)
splitTree (Tree _ []) = error "empty tree"

-- | Preliminaries for the simulation methods. Generate a tree with uniform random labels
--    This uses 'split' to split a random seed
randomTree :: RandomGen g => g -> Tree
randomTree g = let (a, g') = R.random g in Tree a (randomTrees g')

randomTrees :: RandomGen g => g -> [Tree]
randomTrees g = let (g1, g2) = split g in randomTree g1 : randomTrees g2

instance Applicative Sampler where
  pure = Sampler . const
  (<*>) = ap

instance Functor Sampler where fmap = liftM

-- | probabilities for a monad.
-- | Sequencing is done by splitting the tree
-- | and using different bits for different computations.
instance Monad Sampler where
  return = pure
  (Sampler m) >>= f = Sampler \g ->
    let (g1, g2) = splitTree g
        (Sampler m') = f (m g1)
     in m' g2

instance MonadSample Sampler where
  random = Sampler \(Tree r _) -> r

sample :: Sampler a -> IO a
sample m = newStdGen *> (runSampler m . randomTree <$> getStdGen)

independent :: Monad m => m a -> m [a]
independent = sequence . repeat

-- | 'weightedsamples' runs a probability measure and gets out a stream of (result,weight) pairs
weightedsamples :: forall a. Weighted Sampler a -> IO [(a, Log Double)]
weightedsamples = sample . independent . runWeighted

-- wiener :: Prob (Double -> State (Data.Map.Map Double Double) Double)
-- wiener = Prob $ \(Tree _ gs) x -> do
--         modify (Data.Map.insert 0 0)
--         table <- get
--         case Data.Map.lookup x table of
--             Just y -> return y
--             Nothing -> return $ fromMaybe undefined $ do
--                         let lower = do
--                                         l <- findMaxLower x (keys table)
--                                         v <- Data.Map.lookup l table
--                                         return (l,v)
--                         let upper = do {u <- find (> x) (keys table) ;
--                                         v    <- Data.Map.lookup u table ; return (u,v) }
--                         let m = bridge lower x upper
--                         let y = runSampler m (gs !! (1 + size table))
--                         return y

--                                 --  modify (Data.Map.insert x y)

-- findMaxLower :: Double -> [Double] -> Maybe Double
-- findMaxLower d [] = Nothing
-- findMaxLower d (x:xs) = let y = findMaxLower d xs in
--                        case y of
--                            Nothing -> if x < d then Just x else Nothing
--                            Just m -> do
--                                           if x > m && x < d then Just x else Just m

-- bridge :: Maybe (Double,Double) -> Double -> Maybe (Double,Double) -> Prob Double
-- -- not needed since the table is always initialized with (0, 0)
-- -- bridge Nothing y Nothing = if y==0 then return 0 else normal 0 (sqrt y)
-- bridge (Just (x,x')) y Nothing = normal x' (sqrt (y-x))
-- bridge Nothing y (Just (z,z')) = normal z' (sqrt (z-y))
-- bridge (Just (x,x')) y (Just (z,z')) = normal (x' + ((y-x)*(z'-x')/(z-x))) (sqrt ((z-y)*(y-x)/(z-x)))
