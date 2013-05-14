{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

{-# LANGUAGE DeriveGeneric #-}

module Database.PostgreSQL.ORM.Association where

import qualified Data.ByteString as S
import Data.Function
import Data.Functor
import Data.Int
import Data.List
import Data.Maybe
import Data.Monoid
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.ToField
import Database.PostgreSQL.Simple.ToRow
import Database.PostgreSQL.Simple.Types

import GHC.Generics

import Data.AsTypeOf
import Data.GetField
import Database.PostgreSQL.ORM.DBSelect
import Database.PostgreSQL.ORM.Model

newtype TrivParam = TrivParam [Action] deriving (Show)
instance ToRow TrivParam where
  toRow (TrivParam actions) = actions

-- | How to find an @a@ given some predicate on @b@s ('assocSelect'),
-- or a particular @b@ ('assocQuery' and 'assocParam').
data Association a b = Association {
    assocSelect :: !(DBSelect (LookupRow a))
    -- ^ General select returning all fields of @a@ from the join
    -- relation between @a@ and @b@.
  , assocQuery :: !Query
    -- ^ An optimized 'Query' to find all the 'a's associated with a
    -- particular @b@.  This can often be done more efficiently than
    -- through 'assocSelect'.
  , assocParam :: !(b -> TrivParam)
    -- ^ The query parameters for the query returned by 'assocQuery'.
  }

instance Show (Association a b) where
  show assoc = "Association " ++ show (assocSelect assoc) ++ " " ++
               show (assocQuery assoc) ++ " ?"

data GDBRefInfo reftype child parent = DBRefInfo {
    dbrefSelector :: !(child -> GDBRef reftype parent)
    -- ^ Field selector returning a reference.
  , dbrefColumn :: !S.ByteString
    -- ^ Name of the database column storing the reference.
  }

type DBRefInfo = GDBRefInfo NormalRef

data ExtractRef a = ExtractRef deriving (Show)
instance Extractor ExtractRef (GDBRef rt a) (DBRef a) THasOne where
  extract _ (DBRef k) = THasOne $ DBRef k
instance Extractor ExtractRef (GDBRef rt a) (DBRef (As alias a)) THasOne where
  extract _ (DBRef k) = THasOne $ DBRef k
instance Extractor ExtractRef (Maybe (GDBRef rt a)) (DBRef a) THasOne where
  extract _ (Just (DBRef k)) = THasOne $ DBRef k
instance Extractor ExtractRef (Maybe (GDBRef rt a)) (DBRef (As alias a))
         THasOne where
  extract _ (Just (DBRef k)) = THasOne $ DBRef k

instance Show (GDBRefInfo rt c p) where
  show ri = "DBRefInfo ? " ++ show (dbrefColumn ri)

defaultDBRefInfo :: (Model child, Model parent
                    , GetField ExtractRef child (DBRef parent)) =>
                    DBRefInfo child parent
defaultDBRefInfo = ri
  where extractor = (const ExtractRef :: g p -> ExtractRef (DBRef p)) ri
        child = undef2 ri
        childids = modelIdentifiers `gAsTypeOf` child
        ri = DBRefInfo {
            dbrefSelector = getFieldVal extractor
            -- XXX be consistent about whether *Info structs have quoted IDs
          , dbrefColumn = modelQColumns childids !! getFieldPos extractor child
          }

dbrefAssocs :: (Model child, Model parent) => GDBRefInfo rt child parent
               -> (Association child parent, Association parent child)
dbrefAssocs ri = (c_p, p_c)
  where idp = modelIdentifiers `gAsTypeOf1` c_p
        idc = modelIdentifiers `gAsTypeOf1` p_c
        on = " ON " <> modelQPrimaryColumn idp <> " = " <> dbrefColumn ri
        c_p = Association {
            assocSelect = fix $ \r -> (modelDBSelect `asTypeOf` r) {
               selJoins = [Query $ "JOIN " <> modelQTable idp <> on] }
          , assocQuery = Query $ modelSelectFragment idc <>
                         " WHERE " <> dbrefColumn ri <> " = ?"
          , assocParam = \p -> TrivParam [toField $ primaryKey p]
          }
        p_c = Association {
            assocSelect = fix $ \r -> (modelDBSelect `asTypeOf` r) {
               selJoins = [Query $ "JOIN " <> modelQTable idc <> on] }
          , assocQuery = defaultModelLookupQuery idp
          , assocParam = \c -> TrivParam [toField $ dbrefSelector ri c]
          }

has :: (Model a, Model b, GetField ExtractRef b (DBRef a)) => Association a b
has = snd $ dbrefAssocs defaultDBRefInfo

belongsTo :: (Model a, Model b, GetField ExtractRef b (DBRef a)) =>
             Association b a
belongsTo = fst $ dbrefAssocs defaultDBRefInfo


chainAssoc :: Association a b -> Association b c -> Association a (b :. c)
chainAssoc ab bc = Association {
    assocSelect = (assocSelect ab) {
       selJoins = selJoins (assocSelect ab) ++ selJoins (assocSelect bc) }
  , assocQuery = assocQuery ab
  , assocParam = \(b :. _) -> assocParam ab b
  }
                   
data JoinTableInfo a b = JoinTableInfo {
    jtTable :: !S.ByteString     -- ^ Name of the join table in the database
  , jtAllowModification :: !Bool
    -- ^ If 'False', disallow generic join table functions that modify
    -- the database.  The default is 'True' for normal join tables,
    -- but 'False' for 'joinThroughModel', since deleting a join
    -- relationsip through a model will destroy other columns of the
    -- join model.
  , jtColumnA :: !S.ByteString   -- ^ Name of ref to A in join table
  , jtKeyA :: !S.ByteString      -- ^ Name of referenced key field in table A
  , jtColumnB :: !S.ByteString
  , jtKeyB :: !S.ByteString
  } deriving (Show)

joinTableInfoModels :: (Model a, Model b) =>
                       JoinTableInfo a b -> (ModelInfo a, ModelInfo b)
joinTableInfoModels _ = (modelInfo, modelInfo)

joinDefault :: (Model a, Model b) => JoinTableInfo a b
joinDefault = jti
  where (a, b) = joinTableInfoModels jti
        keya = modelColumns a !! modelPrimaryColumn a
        keyb = modelColumns b !! modelPrimaryColumn b
        jti = JoinTableInfo {
            jtTable = S.intercalate "_" $
                      sort [modelTable a, modelTable b]
          , jtAllowModification = True
          , jtColumnA = S.concat [modelTable a, "_", keya]
          , jtKeyA = keya
          , jtColumnB = S.concat [modelTable b, "_", keyb]
          , jtKeyB = keyb
          }

joinThroughModelInfo :: (Model jt, Model a, Model b
                        , GetField ExtractRef jt (DBRef a)
                        , GetField ExtractRef jt (DBRef b)) =>
                        ModelInfo jt -> JoinTableInfo a b
joinThroughModelInfo jt = jti
  where (a, b) = joinTableInfoModels jti
        extractor = const ExtractRef :: ModelInfo a -> ExtractRef (DBRef a)
        jti = JoinTableInfo {
            jtTable = modelTable jt
          , jtAllowModification = False
          , jtColumnA = modelColumns jt !! getFieldPos (extractor a) (undef1 jt)
          , jtKeyA = modelColumns a !! modelPrimaryColumn a
          , jtColumnB = modelColumns jt !! getFieldPos (extractor b) (undef1 jt)
          , jtKeyB = modelColumns b !! modelPrimaryColumn b
          }

joinThroughModel :: (Model jt, Model a, Model b
                    , GetField ExtractRef jt (DBRef a)
                    , GetField ExtractRef jt (DBRef b)) =>
                   jt -> JoinTableInfo a b
joinThroughModel = joinThroughModelInfo . gAsTypeOf modelInfo





data T1 = T1 deriving (Show, Generic)
instance RowAlias T1

data Quizog = Quizog {
    qId :: !DBKey
  , qNone :: !(Maybe Int32)
  , qName :: !String
  , qEd :: !String
  } deriving (Show, Generic)
instance Model Quizog

data RefTest = RefTest { rtId :: DBKey
                       , rtRef :: (Maybe (DBRefUnique Quizog))
                       } deriving (Show, Generic)
instance Model RefTest

refTest :: RefTest
refTest = RefTest NullKey (Just (DBRef 99))

refTest' :: As T1 RefTest
refTest' = As refTest

xx :: Association Quizog RefTest
yy :: Association RefTest Quizog
(yy,xx) = dbrefAssocs defaultDBRefInfo

zz :: Association Quizog RefTest
zz = has

exr :: ExtractRef (DBRef Quizog)
exr = ExtractRef
