{-# LANGUAGE CPP, OverloadedStrings #-}
{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
module Language.Hakaru.Parser.SymbolResolve where

import Data.Text hiding (concat, map, maximum)
#if __GLASGOW_HASKELL__ < 710
import Data.Functor                     ((<$>))
import Control.Applicative              ((<*>))
#endif
import Control.Monad.Trans.State.Strict (State, state, evalState)

import           Language.Hakaru.Types.Sing
import           Language.Hakaru.Types.Coercion
import           Language.Hakaru.Types.HClasses
import           Language.Hakaru.Syntax.IClasses
import qualified Data.Number.Nat as N
import qualified Language.Hakaru.Syntax.AST as T
import qualified Language.Hakaru.Parser.AST as U

data Symbol a
    = TLam (a -> Symbol a)
    | TNeu a

data Symbol' a
    = TLam' ([a] -> a)
    | TNeu' a

primPat :: [(Text, Symbol' U.Pattern)]
primPat =
    [ ("left",    TLam' $ \ [a] ->
           U.PDatum "pLeft" . U.PInl $
            U.PKonst a `U.PEt` U.PDone)
    , ("right",   TLam' $ \ [b] ->
           U.PDatum "pRight" . U.PInr . U.PInl $
            U.PKonst b `U.PEt` U.PDone)
    , ("true",    TNeu' . U.PDatum "pTrue"  . U.PInl $ U.PDone)
    , ("false",   TNeu' . U.PDatum "pFalse" . U.PInr . U.PInl $ U.PDone)
    , ("pair",    TLam' $ \ [a, b] ->
           U.PDatum "pPair" .  U.PInl $
            U.PKonst a `U.PEt` U.PKonst b `U.PEt` U.PDone)
    , ("just",    TLam' $ \ [a] ->
            U.PDatum "pJust" . U.PInr . U.PInl $
             U.PKonst a `U.PEt` U.PDone)
    , ("nothing", TLam' $ \ [] ->
            U.PDatum "tNothing" . U.PInl $ U.PDone)
    ]

primTypes :: [(Text, Symbol' U.SSing)]
primTypes = 
    [ ("nat",     TNeu' $ U.SSing SNat)
    , ("int",     TNeu' $ U.SSing SInt)
    , ("prob",    TNeu' $ U.SSing SProb)
    , ("real",    TNeu' $ U.SSing SReal)
    , ("bool",    TNeu' $ U.SSing sBool)
    , ("measure", TLam' $ \ [U.SSing a] -> U.SSing $ SMeasure a)
    , ("either",  TLam' $ \ [U.SSing a, U.SSing b] -> U.SSing $ sEither a b)
    , ("pair",    TLam' $ \ [U.SSing a, U.SSing b] -> U.SSing $ sPair a b)
    , ("maybe",   TLam' $ \ [U.SSing a] -> U.SSing $ sMaybe a)
    ]

t2 :: (U.AST -> U.AST -> U.AST) -> Symbol U.AST
t2 f = TLam $ \a -> TLam $ \b -> TNeu (f a b)

type SymbolTable a = [(Text, Symbol U.AST)]

primTable :: SymbolTable a
primTable =
    [("pair",       primPair)
    ,("left",       primLeft)
    ,("right",      primRight)
    ,("true",       primTrue)
    ,("false",      primFalse)
    ,("fromProb",   primFromProb)
    ,("unsafeProb", primUnsafeProb)
    ,("uniform",    primMeasure2 (U.SealedOp T.Uniform))
    ,("normal",     primMeasure2 (U.SealedOp T.Normal))
    ,("gamma",      primMeasure2 (U.SealedOp T.Gamma))
    ,("beta",       primMeasure2 (U.SealedOp T.Beta))
    ,("weight",     primWeight)
    ,("dirac",      TLam $ TNeu . U.Dirac_)
    -- This should probably be in U.AST'
    ,("**",         primRealPow)
    --,("^",          primNatPow)
    ]


primMeasure2 :: U.SealedOp T.MeasureOp -> Symbol U.AST
primMeasure2 m = t2 $ \x y -> U.MeasureOp_ m [x, y]

primPair, primLeft, primRight, primTrue, primFalse :: Symbol U.AST
primFromProb, primUnsafeProb  :: Symbol U.AST
primWeight, primRealPow :: Symbol U.AST
primPair       = t2 $ \a b ->
    U.Datum_ $ U.Datum "pair"
        (U.Inl $ U.Konst a `U.Et` U.Konst b `U.Et` U.Done)
primLeft       = TLam $ TNeu . U.Datum_ .
                        U.Datum "left" . U.Inl . (`U.Et` U.Done) . U.Konst
primRight      = TLam $ TNeu . U.Datum_ .
                        U.Datum "right" . U.Inr . U.Inl . (`U.Et` U.Done) . U.Konst
primTrue       = TNeu . U.Datum_ . U.Datum "true"  . U.Inl $ U.Done
primFalse      = TNeu . U.Datum_ . U.Datum "false" . U.Inr . U.Inl $ U.Done
primFromProb   =
    TLam $ TNeu . U.CoerceTo_ (Some2 $ CCons (Signed HRing_Real) CNil)
primUnsafeProb =
    TLam $ TNeu . U.UnsafeTo_ (Some2 $ CCons (Signed HRing_Real) CNil)
primWeight     = t2 $ \w m -> U.Superpose_ [(w, m)]
primRealPow    = t2 $ \x y -> U.PrimOp_ (U.SealedOp T.RealPow) [x, y]
--primNatPow     = t2 $ \x y -> U.PrimOp_ (U.SealedOp T.NatPow) [x, y]

gensym :: Text -> State Int U.Name
gensym s = state $ \i -> (U.Name (N.unsafeNat i) s, i + 1)

mkSym  :: U.Name -> Symbol U.AST
mkSym = TNeu . U.Var_

updateSymbols :: U.Name -> SymbolTable a -> SymbolTable a
updateSymbols n@(U.Name _ name) sym = (name, mkSym n) : sym

updateSymbolsL :: [U.Name] -> SymbolTable a -> SymbolTable a
updateSymbolsL []     sym = sym
updateSymbolsL (n:ns) sym = updateSymbolsL ns (updateSymbols n sym)


resolveBinder
    :: SymbolTable a
    -> Text
    -> U.AST' Text
    -> U.AST' Text
    -> (Symbol U.AST ->
        U.AST' (Symbol U.AST) ->
        U.AST' (Symbol U.AST) ->
        U.AST' (Symbol U.AST))
    -> State Int (U.AST' (Symbol U.AST))
resolveBinder symbols name e1 e2 f = do
  name' <- gensym name
  f (mkSym name')
        <$> symbolResolution symbols e1
        <*> symbolResolution (updateSymbols name' symbols) e2        
    

-- TODO: clean up by merging the @Reader (SymbolTable a)@ and @State Int@ monads
-- | Figure out symbols and types.
symbolResolution
    :: SymbolTable a
    -> U.AST' Text
    -> State Int (U.AST' (Symbol U.AST))
symbolResolution symbols ast =
    case ast of
    U.Var name ->
        case lookup name symbols of
        Nothing -> (U.Var . mkSym) <$> gensym name
        Just a  -> return $ U.Var a

    U.Lam name x -> do
        name' <- gensym name
        U.Lam (mkSym name')
            <$> symbolResolution (updateSymbols name' symbols) x

    U.App f x -> U.App
        <$> symbolResolution symbols f
        <*> symbolResolution symbols x

    U.Let name e1 e2    -> resolveBinder symbols name e1 e2 U.Let
    U.If e1 e2 e3       -> U.If
        <$> symbolResolution symbols e1
        <*> symbolResolution symbols e2
        <*> symbolResolution symbols e3

    U.Ann e typ         -> (`U.Ann` typ) <$> symbolResolution symbols e
    U.Infinity          -> return $ U.Infinity
    U.NegInfinity       -> return $ U.NegInfinity
    U.ULiteral v        -> return $ U.ULiteral v

    U.NaryOp op e1 e2   -> U.NaryOp op
        <$> symbolResolution symbols e1
        <*> symbolResolution symbols e2

    U.Array name e1 e2  -> resolveBinder symbols name e1 e2 U.Array

    U.Case e1 bs        -> U.Case <$> symbolResolution symbols e1
                                  <*> mapM (symbolResolveBranch symbols) bs

    U.Dirac e1          -> U.Dirac <$> symbolResolution symbols e1

    U.Bind name e1 e2   -> resolveBinder symbols name e1 e2 U.Bind
            
    U.Expect name e1 e2 -> resolveBinder symbols name e1 e2 U.Expect            


symbolResolveBranch :: SymbolTable a -> U.Branch' Text ->
                       State Int (U.Branch' (Symbol U.AST))

symbolResolveBranch symbols (U.Branch' pat ast) = do
  (pat', names) <- symbolResolvePat pat
  ast' <- symbolResolution (updateSymbolsL names symbols) ast
  return $ U.Branch'' pat' ast'

symbolResolvePat :: U.Pattern' Text ->
                    State Int (U.Pattern' U.Name, [U.Name])
symbolResolvePat (U.PVar' name) = do name' <- gensym name
                                     return (U.PVar' name', [name'])
symbolResolvePat U.PWild'       = return (U.PWild', [])
symbolResolvePat (U.PData' (U.DV name args)) = do
  args' <- mapM symbolResolvePat args
  let (args'', names) = unzip args'
  return $ (U.PData' (U.DV name args''), concat names)

-- | Make AST and give unique names for variables.
--
-- The logic here is to do normalization by evaluation for our
-- primitives. App inspects its first argument to see if it should
-- do something special. Otherwise App behaves as normal.
normAST :: U.AST' (Symbol U.AST) -> U.AST' (Symbol U.AST)
normAST ast =
    case ast of
    U.Var a           -> U.Var a
    U.Lam name f      -> U.Lam name (normAST f)
    U.App (U.Var t) x ->
        case t of
        TLam f -> U.Var $ f (makeAST $ normAST x)
        TNeu _ -> U.App (U.Var t) (normAST x)

    U.App f x ->
        case normAST f of
        v@(U.Var _) -> normAST (U.App v x)
        f'          -> U.App f' x

    U.Let name e1 e2    -> U.Let name (normAST e1) (normAST e2)
    U.If e1 e2 e3       -> U.If  (normAST e1) (normAST e2) (normAST e3)
    U.Ann e typ1        -> U.Ann (normAST e) typ1
    U.Infinity          -> U.Infinity
    U.NegInfinity       -> U.NegInfinity
    U.ULiteral v        -> U.ULiteral v
    U.NaryOp op e1 e2   -> U.NaryOp op (normAST e1) (normAST e2)
    U.Empty             -> U.Empty
    U.Array name e1 e2  -> U.Array name (normAST e1) (normAST e2)
    U.Case e1 e2        -> U.Case  (normAST e1) (map branchNorm e2)
    U.Dirac e1          -> U.Dirac (normAST e1)
    U.Bind   name e1 e2 -> U.Bind name (normAST e1) (normAST e2)
    U.Expect name e1 e2 -> U.Expect name (normAST e1) (normAST e2)
    U.Data name typ     -> U.Data name typ
    U.WithMeta a meta   -> U.WithMeta (normAST a) meta

branchNorm :: U.Branch' (Symbol U.AST) -> U.Branch' (Symbol U.AST)
branchNorm (U.Branch'  pat e2') = U.Branch'  pat (normAST e2')
branchNorm (U.Branch'' pat e2') = U.Branch'' pat (normAST e2')

makeType :: U.TypeAST' -> U.SSing
makeType (U.TypeVar t) =
    case lookup t primTypes of
    Just (TNeu' t') -> t'
    Nothing         -> error $ "Type " ++ show t ++ " is not a primitive"
makeType (U.TypeFun f x) =
    case (makeType f, makeType x) of
    (U.SSing f', U.SSing x') -> U.SSing $ SFun f' x'
makeType (U.TypeApp f args) =
    case lookup f primTypes of
    Just (TLam' f') -> f' (map makeType args)
    Nothing         -> error $ "Type " ++ show f ++ " is not a primitive"


makePattern :: U.Pattern' U.Name -> U.Pattern
makePattern U.PWild'       = U.PWild
makePattern (U.PVar' name) =
    case lookup (U.hintID name) primPat of
      Just (TLam' _)  -> error "TODO{makePattern:PVar:TLam}"
      Just (TNeu' p') -> p'
      Nothing         -> U.PVar name
makePattern (U.PData' (U.DV name args)) =
    case lookup name primPat of
      Just (TLam' f') -> f' (map makePattern args)
      Just (TNeu' p') -> p'
      Nothing         -> error $ "Data constructor " ++ show name ++ " not found"

makeBranch :: U.Branch' (Symbol U.AST) -> U.Branch
makeBranch (U.Branch'' pat ast) = U.Branch (makePattern pat) (makeAST ast)
makeBranch (U.Branch'  _   _)   = error "branch was not symbol resolved"

makeTrue, makeFalse :: U.AST' (Symbol U.AST) -> U.Branch
makeTrue  e = U.Branch (makePattern (U.PData' (U.DV "true"  []))) (makeAST e)
makeFalse e = U.Branch (makePattern (U.PData' (U.DV "false" []))) (makeAST e)

makeAST :: U.AST' (Symbol U.AST) -> U.AST
makeAST ast =
    case ast of
    U.Var (TLam _)                -> error "makeAST: Wat?"
    U.Var (TNeu e)                -> e
    U.Lam (TNeu (U.Var_ name)) e1 -> U.Lam_ name (makeAST e1)
    U.App e1 e2                   -> U.App_ (makeAST e1) (makeAST e2)
    U.Let (TNeu (U.Var_ name)) e1 e2 ->
        U.Let_ name (makeAST e1) (makeAST e2)
    U.If e1 e2 e3     -> U.Case_ (makeAST e1) [(makeTrue e2), (makeFalse e3)]
    U.Ann e typ       -> U.Ann_ (makeAST e) (makeType typ)
    U.Infinity        -> U.PrimOp_ (U.SealedOp $ T.Infinity) []
    U.NegInfinity     -> U.PrimOp_ (U.SealedOp $ T.NegativeInfinity) []
    U.ULiteral v      -> U.Literal_  (U.val v)
    U.NaryOp op e1 e2 -> U.NaryOp_ op [makeAST e1, makeAST e2]
    U.Array (TNeu (U.Var_ name)) e1 e2 ->
        U.Array_ (makeAST e1) name (makeAST e2)
    U.Case e bs       -> U.Case_ (makeAST e) (map makeBranch bs)
    U.Dirac e1        -> U.Dirac_ (makeAST e1)
    U.Bind (TNeu (U.Var_ name)) e1 e2 ->
        U.MBind_ name (makeAST e1) (makeAST e2)
    U.Expect (TNeu (U.Var_ name)) e1 e2 ->
        U.Expect_ name (makeAST e1) (makeAST e2)


resolveAST :: U.AST' Text -> U.AST
resolveAST ast = makeAST $ normAST $ evalState (symbolResolution primTable ast) 0

data PrimOp'
    = Not'
    | Impl'
    | Diff'
    | Nand'      | Nor'
    | Pi'
    | Sin'       | Cos'   | Tan'
    | Asin'      | Acos'  | Atan'
    | Sinh'      | Cosh'  | Tanh'
    | Asinh'     | Acosh' | Atanh'
    | RealPow'
    | Exp'       | Log'
    | Infinity'  | NegativeInfinity'
    | GammaFunc' | BetaFunc'
    | Integrate' | Summate'
    | Equal'     | Less'
    | NatPow'
    | Negate'
    | Abs'
    | Signum'
    | Recip'
    | NatRoot'
    | Erf'

data ArrayOp'
    = Index'
    | Size'
    | Reduce'


data MeasureOp'
    = Lebesgue'
    | Counting'
    | Categorical'
    | Uniform'
    | Normal'
    | Poisson'
    | Gamma'
    | Beta'
    | DP'
    | Plate'
    | Chain'
