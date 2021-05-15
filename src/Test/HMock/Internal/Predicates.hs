{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Test.HMock.Internal.Predicates where

import Data.Foldable (toList)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf)
import Data.Typeable (Proxy (..), Typeable, cast, typeRep)
import GHC.Stack (HasCallStack, callStack)
import Language.Haskell.TH (ExpQ, PatQ, pprint)
import Language.Haskell.TH.Syntax (lift)
import Test.HMock.Internal.TH.Util (removeModNames)
import Test.HMock.Internal.Util (getSrcLoc, showWithLoc, choices)

-- | A predicate, which tests values and either accepts or rejects them.  This
-- is similar to @a -> 'Bool'@, but also has a 'Show' instance to describe what
-- it is checking.
--
-- Predicates are used to define which arguments a general matcher should
-- accept.
data Predicate a = Predicate
  { showPredicate :: String,
    accept :: a -> Bool
  }

instance Show (Predicate a) where show = showPredicate

-- | A 'Predicate' that accepts only the given value.
eq :: (Show a, Eq a) => a -> Predicate a
eq x =
  Predicate
    { showPredicate = show x,
      accept = (== x)
    }

-- | A 'Predicate' that accepts anything but the given value.
neq :: (Show a, Eq a) => a -> Predicate a
neq x =
  Predicate
    { showPredicate = "≠ " ++ show x,
      accept = (/= x)
    }

-- | A 'Predicate' that accepts anything greater than the given value.
gt :: (Show a, Ord a) => a -> Predicate a
gt x =
  Predicate
    { showPredicate = "> " ++ show x,
      accept = (> x)
    }

-- | A 'Predicate' that accepts anything greater than or equal to the given
-- value.
geq :: (Show a, Ord a) => a -> Predicate a
geq x =
  Predicate
    { showPredicate = "≥ " ++ show x,
      accept = (>= x)
    }

-- | A 'Predicate' that accepts anything less than the given value.
lt :: (Show a, Ord a) => a -> Predicate a
lt x =
  Predicate
    { showPredicate = "< " ++ show x,
      accept = (< x)
    }

-- | A 'Predicate' that accepts anything less than or equal to the given value.
leq :: (Show a, Ord a) => a -> Predicate a
leq x =
  Predicate
    { showPredicate = "≤ " ++ show x,
      accept = (<= x)
    }

-- | A 'Predicate' that accepts anything at all.
anything :: Predicate a
anything =
  Predicate
    { showPredicate = "anything",
      accept = const True
    }

-- | A 'Predicate' that accepts anything accepted by both of its children.
andP :: Predicate a -> Predicate a -> Predicate a
p `andP` q =
  Predicate
    { showPredicate = showPredicate p ++ " and " ++ showPredicate q,
      accept = \x -> accept p x && accept q x
    }

-- | A 'Predicate' that accepts anything accepted by either of its children.
orP :: Predicate a -> Predicate a -> Predicate a
p `orP` q =
  Predicate
    { showPredicate = showPredicate p ++ " or " ++ showPredicate q,
      accept = \x -> accept p x || accept q x
    }

-- | A 'Predicate' that inverts another 'Predicate', accepting whatever its
-- child rejects, and rejecting whatever its child accepts.
notP :: Predicate a -> Predicate a
notP p =
  Predicate
    { showPredicate = "not " ++ showPredicate p,
      accept = not . accept p
    }

-- | A 'Predicate' that accepts lists or 'String's that start with the given
-- prefix.
startsWith :: (Eq a, Show a) => [a] -> Predicate [a]
startsWith s =
  Predicate
    { showPredicate = "starts with " ++ show s,
      accept = (s `isPrefixOf`)
    }

-- | A 'Predicate' that accepts lists or 'String's that and with the given
-- suffix.
endsWith :: (Eq a, Show a) => [a] -> Predicate [a]
endsWith s =
  Predicate
    { showPredicate = "ends with " ++ show s,
      accept = (s `isSuffixOf`)
    }

-- | A 'Predicate' that accepts lists or 'String's that contain the given
-- subsequence or substring.
hasSubstr :: (Eq a, Show a) => [a] -> Predicate [a]
hasSubstr s =
  Predicate
    { showPredicate = "has substring " ++ show s,
      accept = (s `isInfixOf`)
    }

-- | A 'Predicate' that accepts lists or other 'Foldable' structures whose
-- number of elements match the child 'Predicate'.
sizeIs :: Foldable t => Predicate Int -> Predicate (t a)
sizeIs p =
  Predicate
    { showPredicate = "size " ++ showPredicate p,
      accept = accept p . length
    }

-- | A 'Predicate' that accepts lists or other 'Foldable' structures of a fixed
-- size, whose contents match the corresponding 'Predicate' in the given list.
elemsAre :: Foldable t => [Predicate a] -> Predicate (t a)
elemsAre ps =
  Predicate
    { showPredicate = "[" ++ intercalate ", " (map showPredicate ps) ++ "]",
      accept = \xs -> length xs == length ps
        && and (zipWith accept ps (toList xs))
    }

-- | A 'Predicate' that accepts lists or other 'Foldable' structures of a fixed
-- size, whose contents match the corresponding 'Predicate' in the given list
-- in any order.
unorderedElemsAre :: Foldable t => [Predicate a] -> Predicate (t a)
unorderedElemsAre ps =
  Predicate
    { showPredicate =
        "(any order) ["
          ++ intercalate ", " (map showPredicate ps)
          ++ "]",
      accept = \xs -> length xs == length ps && matches ps (toList xs)
    }
  where
    matches (q:qs) xs = or [ matches qs ys | (y, ys) <- choices xs, accept q y ]
    matches [] _ = True

-- | A 'Predicate' that accepts lists or other 'Foldable' structures whose
-- elements all match the child 'Predicate'.
allElemsAre :: Foldable t => Predicate a -> Predicate (t a)
allElemsAre p =
  Predicate
    { showPredicate = "all " ++ showPredicate p,
      accept = all (accept p)
    }

-- | A 'Predicate' that accepts lists or other 'Foldable' structures which
-- contain at least one element matching the child 'Predicate'.
anyElemIs :: Foldable t => Predicate a -> Predicate (t a)
anyElemIs p =
  Predicate
    { showPredicate = "any " ++ showPredicate p,
      accept = any (accept p)
    }

-- | A conversion from @a -> 'Bool'@ to 'Predicate'.  This is a fallback that
-- can be used to build a 'Predicate' that checks anything at all.  However, its
-- description will be less helpful than standard 'Predicate's.
suchThat :: HasCallStack => (a -> Bool) -> Predicate a
suchThat f =
  Predicate
    { showPredicate = showWithLoc (getSrcLoc callStack) "custom predicate",
      accept = f
    }

-- | A Template Haskell splice that turns a pattern into a predicate that
-- accepts values that match the pattern.
--
-- You would use this in a splice with a TH-quoted pattern argument, as in
-- @$('match' [p| Just (Left _) |])@.
match :: PatQ -> ExpQ
match qpat =
  [|
    Predicate
      { showPredicate = $(lift . pprint . removeModNames =<< qpat),
        accept = \case
          $(qpat) -> True
          _ -> False
      }
    |]

-- | Converts a 'Predicate' to a new type.  Typically used with visible type
-- application, as in @'typed' @Int ('lt' 42)@.  This will only match if the
-- argument is an Int, and also less than 42.
typed :: forall a b. (Typeable a, Typeable b) => Predicate a -> Predicate b
typed p =
  Predicate
    { showPredicate =
        showPredicate p ++ " :: " ++ show (typeRep (Proxy :: Proxy a)),
      accept = \x -> case cast x of
        Nothing -> False
        Just y -> accept p y
    }
