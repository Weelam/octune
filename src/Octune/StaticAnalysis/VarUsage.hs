{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings    #-}

module Octune.StaticAnalysis.VarUsage where

import           Control.Lens
import           Data.Text.Lens

import           Data.Foldable

import           Data.Graph          (Graph)
import qualified Data.Graph          as Graph
import qualified Data.Map.Strict     as Map

import           Data.Text           (Text)
import qualified Data.Text           as T

import           Text.Megaparsec.Pos

import           Octune.Types

-- Checks that variables used have all been declared
checkVarsDeclared :: Env (AST Ann) -> Either Text ()
checkVarsDeclared env = traverse_ (uncurry checkDeclRhs) (Map.toList env)
  where
    checkDeclRhs :: QualifiedName -> AST Ann -> Either Text ()
    checkDeclRhs qDeclName (Song _ _ expr) =
        checkDeclRhs qDeclName expr
    checkDeclRhs qDeclName (Var ann qVarName) =
        case Map.lookup qVarName env of
            Nothing ->
                Left $ mconcat
                    [ ann ^. pos . to sourcePosPretty . packed
                    , ":\nUndefined variable `"
                    , variableName qVarName
                    , "` in module `"
                    , T.intercalate "." (moduleQual qVarName)
                    , "` used in the declaration of `"
                    , variableName qDeclName
                    , "` in module `"
                    , T.intercalate "." (moduleQual qDeclName)
                    , "`"
                    ]
            Just _ ->
                pure ()
    checkDeclRhs _ LineNote{} =
        pure ()
    checkDeclRhs declName (LineApp _ _ args) =
        traverse_ (checkDeclRhs declName) args
    checkDeclRhs _ BeatsAssertion{} =
        pure ()
    checkDeclRhs _ _ = error "Should not have File or Decl from parsing"

-- Checks that usages of variables don't form a cycle
checkNoVarCycles :: Env (AST Ann) -> Either Text ()
checkNoVarCycles env = errorOnSelfEdges *> errorOnCycles
  where
    edgesFromVar
        :: QualifiedName
        -> AST Ann
        -> (QualifiedName, QualifiedName, [QualifiedName])
    edgesFromVar v expr = (v, v, varsIn expr)

    varsIn :: AST Ann -> [QualifiedName]
    varsIn (Song _ _ expr)    = varsIn expr
    varsIn (Var _ v)          = [v]
    varsIn LineNote{}         = []
    varsIn (LineApp _ _ args) = foldl' (\a c -> varsIn c ++ a) [] args
    varsIn BeatsAssertion{}   = []
    varsIn _ = error "Should not have File or Decl from parsing"

    -- Graph from variables to the variables that appear in their declaration
    varGraph :: Graph
    (varGraph, varNodeFromVertex, _) =
        Graph.graphFromEdges $ fmap (uncurry edgesFromVar) (Map.toList env)

    varFromVertex :: Graph.Vertex -> QualifiedName
    varFromVertex vertex = let (v,_,_) = varNodeFromVertex vertex in v

    errorOnSelfEdges :: Either Text ()
    errorOnSelfEdges =
        case filter (uncurry (==)) (Graph.edges varGraph) of
            [] -> pure ()
            cs ->
                Left $ mconcat
                    [ "Variables cannot reference themselves:\n"
                    , T.unlines $ fmap (T.append "    - ") badVars
                    ]
                  where
                    showVar = denoteVar . varFromVertex . fst
                    badVars = fmap showVar cs
    errorOnCycles :: Either Text ()
    errorOnCycles =
        case filter ((> 1) . length) (Graph.scc varGraph) of
            [] -> pure ()
            cs ->
                Left $ mconcat
                    [ "Variable usages cannot form a cycle:\n"
                    , T.unlines $ fmap (T.append "\t- ") badComponents
                    ]
                  where
                    showComponent component =
                        let cycleVars@(v:_) =
                                fmap
                                    (denoteVar . varFromVertex)
                                    (toList component)
                         in T.intercalate " -> " (cycleVars ++ [v,"..."])
                    badComponents = fmap showComponent cs

    denoteVar :: QualifiedName -> Text
    denoteVar qName =
        mconcat
            [ "`"
            , T.intercalate "." (moduleQual qName)
            , "."
            , variableName qName
            , "`"
            ]
