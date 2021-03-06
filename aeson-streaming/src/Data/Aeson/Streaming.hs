{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE InstanceSigs #-}

module Data.Aeson.Streaming (
  Path(..)
, Parser
, parse
, parseL
, SomeParseResult(..)
, SomeArrayParser(..)
, SomeObjectParser(..)
, NextParser
, ParseResult(.., AtomicResult)
, Compound(..)
, Element(..)
, Index
, PathComponent(..)
, PathableIndex(..)
, atom
, root
, skipValue
, skipRestOfCompound
, parseValue
, decodeValue
, decodeValue'
, parseRestOfArray
, parseRestOfObject
, navigateFromTo
, navigateFromTo'
, navigateTo
, navigateTo'
, findElement
, findElement'
, jpath
) where

import Control.Monad
import qualified Control.Monad.Fail as Fail
import qualified Data.Aeson as A
import qualified Data.Aeson.Streaming.Internal as S
import Data.Aeson.Streaming.Internal (Compound(..), Path(..), Index,
                                      PathComponent(..), PathableIndex(..),
                                      jpath)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Attoparsec.ByteString as AP
import qualified Data.Attoparsec.ByteString.Lazy as APL
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)
import Data.Scientific (Scientific)
import qualified Data.Vector as V

-- | A parser akin to an Attoparsec `AP.Parser`, but without
-- backtracking capabilities, which allows it to discard its input as
-- it is used.
newtype Parser a = Parser (ByteString -> AP.Result a)

data SomeParseResult = forall p. SomeParseResult (ParseResult p)

-- | A wrapper that allows a function to return a parser positioned
-- within an arbitarily deeply nested array, forgetting the path it
-- took to get there.
data SomeArrayParser = forall p. SomeArrayParser (Parser (Element 'Array p))

-- | A wrapper that allows a function to return a parser positioned
-- within an arbitarily deeply nested object, forgetting the path it
-- took to get there.
data SomeObjectParser = forall p. SomeObjectParser (Parser (Element 'Object p))

-- | Apply a parser to a `ByteString` to start the parsing process.
parse :: Parser a -> ByteString -> AP.Result a
parse (Parser f) = f

-- | Apply a parser to a lazy `BSL.ByteString`.
parseL :: Parser a -> BSL.ByteString -> APL.Result a
parseL p = go (parse p) . BSL.toChunks
  where go f [] = convert [] $ f BS.empty
        go f (bs : bss) = convert bss $ f bs
        convert bss (AP.Done bs r) = APL.Done (prepend bs bss) r
        convert bss (AP.Fail bs a b) = APL.Fail (prepend bs bss) a b
        convert bss (AP.Partial f') = go f' bss
        prepend bs bss = BSL.fromChunks (bs : bss)

instance Functor Parser where
  fmap f (Parser p) = Parser (fmap f . p)

instance Applicative Parser where
  pure a = Parser (flip AP.Done a)
  Parser f <*> Parser r = Parser $ parseLoop result f
    where
      result f' = fmap f' . r

instance Monad Parser where
  (Parser f) >>= next = Parser $ parseLoop (parse . next) f
  fail = Fail.fail

instance Fail.MonadFail Parser where
  fail err = Parser $ AP.parse (fail err)

parseLoop :: (i -> ByteString -> AP.Result r) -> (ByteString -> AP.Result i) -> ByteString -> AP.Result r
parseLoop result = go
  where
    go f bs =
      case f bs of
        AP.Done leftover i | BS.null leftover -> AP.Partial (result i)
                           | otherwise -> result i leftover
        AP.Fail x y z -> AP.Fail x y z
        AP.Partial f' -> AP.Partial (go f')

-- | When parsing nested values, this type indicates whether a new
-- element has been parsed or if the end of the compound has arrived.
data Element (c :: Compound) (p :: Path)
  = Element !(Index c) (ParseResult ('In c p))
  -- ^ There is a new element with the provided index.
  | End (NextParser p)
  -- ^ There are no more elements.  The parser returned will continue
  -- with the container's parent.

-- | When we're done reading an object, whether there is more to parse
-- depends on the current path to the root.  This is a function from
-- the current path to the next parser for reading more values.
type family NextParser (p :: Path) = r | r -> p where
  NextParser 'Root = ()
  NextParser ('In c p) = Parser (Element c p)

-- | One step of parsing can produce either one of the atomic JSON
-- types (null, string, boolean, number) or a parser that can consume
-- one of the compound types (array, object)
data ParseResult (p :: Path)
  = ArrayResult (Parser (Element 'Array p))
  -- ^ We've seen a @[@ and have a parser for producing the elements
  -- of the array.
  | ObjectResult (Parser (Element 'Object p))
  -- ^ We've seen a @{@ and have a parser for producing the elements
  -- of the array.
  | NullResult (NextParser p)
  -- ^ We've seen and consumed a @null@
  | StringResult (NextParser p) Text
  -- ^ We've seen an consumed a string
  | BoolResult (NextParser p) Bool
  -- ^ We've seen and cosumed a boolean
  | NumberResult (NextParser p) Scientific
  -- ^ We've seen and consumed a number

-- | Match an atomic `ParseResult` as a `A.Value`.
pattern AtomicResult :: NextParser p -> A.Value -> ParseResult p
pattern AtomicResult p v <- (atom -> Just (p, v))
{-# COMPLETE AtomicResult, ArrayResult, ObjectResult #-}

-- | Extract an atomic `A.Value` from a `ParseResult` if it is one.
atom :: ParseResult p -> Maybe (NextParser p, A.Value)
atom (NullResult p) = Just (p, A.Null)
atom (StringResult p s) = Just (p, A.String s)
atom (BoolResult p b) = Just (p, A.Bool b)
atom (NumberResult p n) = Just (p, A.Number n)
atom _ = Nothing
{-# INLINE atom #-}

-- | A parser for a top-level value.
root :: Parser (ParseResult 'Root)
root = Parser $ AP.parse (convertResult <$> S.root)

class ParserConverter (p :: Path) where
  convertParser :: S.NextParser p -> NextParser p

instance ParserConverter 'Root where
  convertParser () = ()

instance (ParserConverter p) => ParserConverter ('In c p) where
  convertParser parser = Parser $ AP.parse (convertElement <$> parser)

convertElement :: (ParserConverter p) => S.Element c p -> Element c p
convertElement (S.Element index r) = Element index (convertResult r)
convertElement (S.End p) = End (convertParser p)

convertResult :: (ParserConverter p) => S.ParseResult p -> ParseResult p
convertResult (S.ArrayResult p) = ArrayResult (convertParser p)
convertResult (S.ObjectResult p) = ObjectResult (convertParser p)
convertResult (S.NullResult p) = NullResult (convertParser p)
convertResult (S.NumberResult p n) = NumberResult (convertParser p) n
convertResult (S.StringResult p s) = StringResult (convertParser p) s
convertResult (S.BoolResult p b) = BoolResult (convertParser p) b

-- | Skip the rest of current value.  This is a no-op for atoms, and
-- consumes the rest of the current object or array otherwise.
skipValue :: ParseResult p -> Parser (NextParser p)
skipValue (ArrayResult p) = skipRestOfCompound p
skipValue (ObjectResult p) = skipRestOfCompound p
skipValue (AtomicResult p _) = pure p

-- | Skip the rest of the current array or object.
skipRestOfCompound :: Parser (Element c p) -> Parser (NextParser p)
skipRestOfCompound = go
  where
    go p =
      p >>= \case
        Element _ r -> go =<< skipValue r
        End n -> pure n

-- | Parse the whole of the current value from the current position.
-- This consumes nothing if the current value is atomic.
parseValue :: ParseResult p -> Parser (NextParser p, A.Value)
parseValue (ObjectResult cont) = fmap A.Object <$> parseRestOfObject cont
parseValue (ArrayResult cont) = fmap A.Array <$> parseRestOfArray cont
parseValue (AtomicResult cont value) = pure (cont, value)

-- | Decode a value via a `A.FromJSON` instance.
decodeValue :: (A.FromJSON a) => ParseResult p -> Parser (NextParser p, A.Result a)
decodeValue p = fmap A.fromJSON <$> parseValue p

-- | Decode a value via a `A.FromJSON` instance, failing the parse if
-- the decoding fails.
decodeValue' :: (A.FromJSON a) => ParseResult p -> Parser (NextParser p, a)
decodeValue' p =
  decodeValue p >>= \case
    (p', A.Success v) -> pure (p', v)
    (_, A.Error s) -> fail s

parseRestOfCompound :: (Index c -> A.Value -> e) -> ([e] -> r) -> Parser (Element c p) -> Parser (NextParser p, r)
parseRestOfCompound interest complete p0 = go p0 []
  where
    go p acc =
      p >>= \case
        Element k pr -> do
          (p', v) <- parseValue pr
          go p' (interest k v : acc)
        End p' ->
          pure (p', complete acc)

-- | Parse the rest of the current object into an `A.Object`.
parseRestOfObject :: Parser (Element 'Object p) -> Parser (NextParser p, A.Object)
parseRestOfObject = parseRestOfCompound (,) HM.fromList

-- | Parse the rest of the current array into an `A.Array`.
parseRestOfArray :: Parser (Element 'Array p) -> Parser (NextParser p, A.Array)
parseRestOfArray = parseRestOfCompound (\_ v -> v) (V.fromList . reverse)

-- | Navigate deeper into a tree, forgetting the path taken to get
-- there.  Returns either a ParseResult for the start of the
-- desired item or the path prefix at which the navigation failed
-- together with `Just` the parse result at that point if the failure
-- was due to a component being the wrong type or `Nothing` if it was
-- due to the desired index not being there.
navigateFromTo :: [PathComponent] -> ParseResult p -> Parser (Either ([PathComponent], Maybe SomeParseResult) SomeParseResult)
navigateFromTo = go []
  where
    go :: [PathComponent] -> [PathComponent] -> ParseResult p -> Parser (Either ([PathComponent], Maybe SomeParseResult) SomeParseResult)
    go _ [] r = pure . Right $ SomeParseResult r
    go path (idx@(Offset i) : rest) (ArrayResult p') = continue (idx:path) rest =<< findElement i =<< p'
    go path (idx@(Field f) : rest) (ObjectResult p') = continue (idx:path) rest =<< findElement f =<< p'
    go path (idx : _) r = pure $ Left (reverse (idx : path), Just $ SomeParseResult r)
    continue path _ (Left _) = pure $ Left (reverse path, Nothing)
    continue path rest (Right r) = go path rest r

-- | Like `navigateFromTo` but fails if the result can't be found
navigateFromTo' :: [PathComponent] -> ParseResult p -> Parser SomeParseResult
navigateFromTo' startPath startPoint =
  navigateFromTo startPath startPoint >>= \case
    Right r -> pure r
    Left (pc, Nothing) -> fail $ "Didn't find element at " ++ show pc
    Left (pc, Just _) -> fail $ "Didn't find the right kind of element at " ++ show pc

-- | Navigate to a particular point in the input object, forgetting
-- the path taken to get there.  This is the same as `navigateFromTo`
-- using `root` as the starting point.
navigateTo :: [PathComponent] -> Parser (Either ([PathComponent], Maybe SomeParseResult) SomeParseResult)
navigateTo path = navigateFromTo path =<< root

-- | Like `navigateTo` but fails if the result can't be found
navigateTo' :: [PathComponent] -> Parser SomeParseResult
navigateTo' path = navigateFromTo' path =<< root

-- | Find an element in the current compound item, returning either a
-- parse result for the start of the found item or a parser for
-- continuing to parse after the end of the compound.
findElement :: (Eq (Index c)) => Index c -> Element c p -> Parser (Either (NextParser p) (ParseResult ('In c p)))
findElement i (Element e r)
  | e == i = pure $ Right r
  | otherwise = findElement i =<< join (skipValue r)
findElement _ (End p) = pure $ Left p

-- | Like `findElement` but fails if the result can't be found
findElement' :: (Show (Index c), Eq (Index c)) => Index c -> Element c p -> Parser (ParseResult ('In c p))
findElement' i p =
  findElement i p >>= \case
    Right r -> pure r
    Left _ -> fail $ "Didn't find the element at " ++ show i
