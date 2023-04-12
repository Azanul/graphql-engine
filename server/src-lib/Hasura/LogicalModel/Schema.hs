{-# LANGUAGE QuasiQuotes #-}

-- | Schema parsers for logical models.
module Hasura.LogicalModel.Schema (defaultBuildLogicalModelRootFields) where

import Data.Has (Has (getter))
import Data.HashMap.Strict qualified as HM
import Data.Monoid (Ap (Ap, getAp))
import Hasura.CustomReturnType.Schema
import Hasura.GraphQL.Schema.Backend
  ( BackendCustomReturnTypeSelectSchema (..),
    BackendSchema (columnParser),
    MonadBuildSchema,
  )
import Hasura.GraphQL.Schema.Common
  ( SchemaT,
    retrieve,
  )
import Hasura.GraphQL.Schema.Options qualified as Options
import Hasura.GraphQL.Schema.Parser qualified as P
import Hasura.LogicalModel.Cache (LogicalModelInfo (..))
import Hasura.LogicalModel.IR (LogicalModel (..))
import Hasura.LogicalModel.Metadata (InterpolatedQuery (..), LogicalModelArgumentName (..))
import Hasura.LogicalModel.Types (NullableScalarType (..), getLogicalModelName)
import Hasura.Prelude
import Hasura.RQL.IR.Root (RemoteRelationshipField)
import Hasura.RQL.IR.Select (QueryDB (QDBMultipleRows))
import Hasura.RQL.IR.Select qualified as IR
import Hasura.RQL.IR.Value (Provenance (FromInternal), UnpreparedValue (UVParameter), openValueOrigin)
import Hasura.RQL.Types.Column qualified as Column
import Hasura.RQL.Types.Metadata.Object qualified as MO
import Hasura.RQL.Types.Source
  ( SourceInfo (_siCustomization, _siName),
  )
import Hasura.RQL.Types.SourceCustomization
  ( ResolvedSourceCustomization (_rscNamingConvention),
  )
import Hasura.SQL.AnyBackend (mkAnyBackend)
import Language.GraphQL.Draft.Syntax qualified as G
import Language.GraphQL.Draft.Syntax.QQ qualified as G

defaultBuildLogicalModelRootFields ::
  forall b r m n.
  ( MonadBuildSchema b r m n,
    BackendCustomReturnTypeSelectSchema b
  ) =>
  LogicalModelInfo b ->
  SchemaT
    r
    m
    (Maybe (P.FieldParser n (QueryDB b (RemoteRelationshipField UnpreparedValue) (UnpreparedValue b))))
defaultBuildLogicalModelRootFields LogicalModelInfo {..} = runMaybeT $ do
  let fieldName = getLogicalModelName _lmiRootFieldName

  logicalModelArgsParser <-
    logicalModelArgumentsSchema @b @r @m @n fieldName _lmiArguments

  sourceInfo :: SourceInfo b <- asks getter

  let sourceName = _siName sourceInfo
      tCase = _rscNamingConvention $ _siCustomization sourceInfo
      description = G.Description <$> _lmiDescription

  stringifyNumbers <- retrieve Options.soStringifyNumbers

  customReturnTypePermissions <-
    MaybeT . fmap Just $
      buildCustomReturnTypePermissions @b @r @m @n _lmiReturns

  (selectionSetParser, customTypesArgsParser) <-
    MaybeT $ buildCustomReturnTypeFields _lmiReturns

  let interpolatedQuery lmArgs =
        InterpolatedQuery $
          (fmap . fmap)
            ( \var@(LogicalModelArgumentName name) -> case HM.lookup var lmArgs of
                Just arg -> UVParameter (FromInternal name) arg
                Nothing ->
                  -- the `logicalModelArgsParser` will already have checked
                  -- we have all the args the query needs so this _should
                  -- not_ happen
                  error $ "No logical model arg passed for " <> show var
            )
            (getInterpolatedQuery _lmiCode)

  let sourceObj =
        MO.MOSourceObjId
          sourceName
          (mkAnyBackend $ MO.SMOLogicalModel @b _lmiRootFieldName)

  pure $
    P.setFieldParserOrigin sourceObj $
      P.subselection
        fieldName
        description
        ( (,)
            <$> customTypesArgsParser
            <*> logicalModelArgsParser
        )
        selectionSetParser
        <&> \((crtArgs, lmArgs), fields) ->
          QDBMultipleRows $
            IR.AnnSelectG
              { IR._asnFields = fields,
                IR._asnFrom =
                  IR.FromLogicalModel
                    LogicalModel
                      { lmRootFieldName = _lmiRootFieldName,
                        lmArgs,
                        lmInterpolatedQuery = interpolatedQuery lmArgs,
                        lmReturnType = buildCustomReturnTypeIR _lmiReturns
                      },
                IR._asnPerm = customReturnTypePermissions,
                IR._asnArgs = crtArgs,
                IR._asnStrfyNum = stringifyNumbers,
                IR._asnNamingConvention = Just tCase
              }

logicalModelArgumentsSchema ::
  forall b r m n.
  MonadBuildSchema b r m n =>
  G.Name ->
  HashMap LogicalModelArgumentName (NullableScalarType b) ->
  MaybeT (SchemaT r m) (P.InputFieldsParser n (HashMap LogicalModelArgumentName (Column.ColumnValue b)))
logicalModelArgumentsSchema logicalModelName argsSignature = do
  -- Lift 'SchemaT r m (InputFieldsParser ..)' into a monoid using Applicative.
  -- This lets us use 'foldMap' + monoid structure of hashmaps to avoid awkwardly
  -- traversing the arguments and building the resulting parser.
  argsParser <-
    getAp $
      foldMap
        ( \(name, NullableScalarType {nstType, nstNullable, nstDescription}) -> Ap do
            argValueParser <-
              fmap (HM.singleton name . openValueOrigin)
                <$> lift (columnParser (Column.ColumnScalar nstType) (G.Nullability nstNullable))
            -- TODO: Naming conventions?
            -- TODO: Custom fields? (Probably not)
            argName <- hoistMaybe (G.mkName (getLogicalModelArgumentName name))
            let description = case nstDescription of
                  Just desc -> G.Description desc
                  Nothing -> G.Description ("Logical model argument " <> getLogicalModelArgumentName name)
            pure $
              P.field
                argName
                (Just description)
                argValueParser
        )
        (HM.toList argsSignature)

  let desc = Just $ G.Description $ G.unName logicalModelName <> " Logical Model Arguments"

  pure $
    if null argsSignature
      then mempty
      else
        P.field
          [G.name|args|]
          desc
          (P.object (logicalModelName <> [G.name|_arguments|]) desc argsParser)
