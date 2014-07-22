{-# LANGUAGE OverloadedStrings #-}
module Handler.Review where

import Import

import Data.Text (pack, lines)
import Data.Text.Encoding (decodeUtf8)
import Data.ByteString.Lazy (toStrict)
import Data.List (transpose, groupBy, head)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Function (on)
import Control.Arrow ((&&&))

import Github.Data.Definitions (DetailedPullRequest(..))
import Github.PullRequests (pullRequest)
import Network.Wreq (getWith, defaults, header, responseBody)
import Control.Lens ((&), (.~), (^.))

import Text.Diff.Parse (parseDiff)
import qualified Text.Diff.Parse.Types as D

import Debug.Trace

traceShowId a = trace (show a) a

{- source.txt
Line 1
Line 2
Line 3
Line 4
Line 5
Line 6
Line 7
Line 8
Line 9
Line 10
Line 11
Line 12
Line 13
Line 14
Line 15
Line 16
Line 17
Line 18
Line 19
Line 20
-}

{- dest.txt
Line 1
Replace 2
Line 3
Line 4
Insert 4.5
Insert 4.6
Line 5
Line 8
Line 9
Replace x
Replace y
Line 13
Line 14
Line 15
Replace a
Replace b
Replace c
Line 17
Line 18
Line 19
Line 20
-}

{-$ diff -u0 source.txt dest.txt
--- source.txt  2014-07-16 05:58:00.253622979 -0400
+++ dest.txt    2014-07-16 05:59:12.193620434 -0400
@@ -2 +2 @@
-Line 2
+Replace 2
@@ -4,0 +5,2 @@
+Insert 4.5
+Insert 4.6
@@ -6,2 +7,0 @@
-Line 6
-Line 7
@@ -10,3 +10,2 @@
-Line 10
-Line 11
-Line 12
+Replace x
+Replace y
@@ -16 +15,3 @@
-Line 16
+Replace a
+Replace b
+Replace c
-}

data Hunk = Hunk (Int, Int) (Int, Int) [Text]
    deriving (Eq, Show)

data Context = Context (Maybe Hunk) (Maybe Hunk)
data FileDiffPart = Change [DiffLine] [DiffLine]
                  | InitialContext [ContextLine]
                  | InternalContext [ContextLine]
                  | FinalContext [ContextLine]

data FileDiffTag = Within Hunk
                 | Before
                 | Between Hunk Hunk
                 | After Hunk
    deriving (Eq, Show)

type NumberedLine = (Int, Text)
type DiffLine = (Int, Text)
type ContextLine = (Int, Int, Text)
type Source = [NumberedLine]

contextSize = 3

dummySourceFile :: Text
dummySourceFile = pack $ unlines ["Line " ++ show l | l <- [1..20]]

dummyHunks :: [Hunk]
dummyHunks = [
    Hunk (2, 1) (2, 1) ["Replace 2"], -- Single line substitution
    Hunk (4, 0) (5, 2) ["Insert 4.5", "Insert 4.6"], -- Insertion
    Hunk (6, 2) (7, 0) [], -- Deletion
    Hunk (10, 3) (10, 2) ["Replace x", "Replace y"], -- Replacement with fewer lines
    Hunk (16, 1) (15, 3) ["Replace a", "Replace b", "Replace c"] -- Replacement with more lines
    ]

sourceLines :: Source -> Hunk -> [NumberedLine]
sourceLines source (Hunk (lStart, lLength) _ _) = take lLength $ drop (lStart - 1) $ source

destLines :: Hunk -> [NumberedLine]
destLines (Hunk _ (rStart, _) text) = zip [rStart..] text

fillInContext :: Source -> [Hunk] -> [FileDiffPart]
fillInContext source hs = map (uncurry mkDiffPart) $ groupAList $ traceShowId $ lineTags hs source

groupAList :: (Eq a) => [(a, b)] -> [(a, [b])]
groupAList xs = map (fst . head &&& map snd) $ groupBy ((==) `on` fst) xs

mkDiffPart :: FileDiffTag -> [NumberedLine] -> FileDiffPart
mkDiffPart Before ls = InitialContext $ addContext ls [1..]
mkDiffPart (Within (Hunk _ (rStart, _) txt)) ls = Change ls (zip [rStart..] txt)
mkDiffPart (After (Hunk _ (start, length) _)) ls = FinalContext $ addContext ls [start + length..]
mkDiffPart (Between (Hunk _ (start, length) _) _) ls = InternalContext $ addContext ls [start + length..]

addContext :: [NumberedLine] -> [Int] -> [ContextLine]
addContext src destNums = zip3 srcNums destNums srcLines
    where (srcNums, srcLines) = unzip src

-- Must be called with a non-empty sorted list of hunks
lineTags :: [Hunk] -> [NumberedLine] -> [(FileDiffTag, NumberedLine)]
lineTags hunks lines = go Nothing hunks lines
    where
        go _ _ [] = []
        go Nothing [] ls = zip (repeat Before) ls
        go (Just h) [] ls = zip (repeat $ After h) ls
        go prev (h@(Hunk (start, len) (_, _) _):hs) (l@(n, t):ls)
            | n < start = (maybe Before (\h' -> Between h h') prev, l):(go prev (h:hs) ls)
            | n >= start && n <= start + len = (Within h, l):(go (Just h) (h:hs) ls)
            | n > start + len = (maybeHead (After h) (Between h) hs, l):(go (Just h) hs ls)

maybeHead def f = maybe def f . listToMaybe

trimContext :: D.Hunk -> [Hunk]
trimContext hunk = trim (D.rangeStartingLineNumber $ D.hunkSourceRange hunk) (D.rangeStartingLineNumber $ D.hunkDestRange hunk) groups
    where
        isContext = (D.Context ==) . D.lineAnnotation
        groups = groupBy ((==) `on` isContext) $ D.hunkLines hunk
        trim _ _ [] = []
        trim srcStart dstStart (g:gs)
            | isContext $ head g = trim (srcStart + length g) (dstStart + length g) gs
            | otherwise = hunk':rest
                where
                    hunk' = Hunk (srcStart, length removed) (dstStart, length added) (map D.lineContent added)
                    rest = trim (srcStart + length removed) (dstStart + length added) gs
                    added = filter ((D.Added ==) . D.lineAnnotation) g
                    removed = filter ((D.Removed ==) . D.lineAnnotation) g


diffToHunks :: D.FileDelta -> [Hunk]
diffToHunks delta = trimContext $ head $ D.fileDeltaHunks delta

hunksForPR :: PullRequest -> IO ([Hunk], Source)
hunksForPR pr = do
    prMetaResult <- pullRequest "edx" "edx-platform" pr
    prMeta <- case prMetaResult of
        Left err -> error $ show err
        Right prMeta -> return $ prMeta
    let diffOpts = defaults & header "Accept-Charset" .~ ["utf-8"]
    diffResponse <- getWith diffOpts $ traceShowId $ detailedPullRequestDiffUrl prMeta
    hunks <- case parseDiff $ traceShowId $ decodeUtf8 $ toStrict (diffResponse ^. responseBody) of
        Left err -> error $ "Error parsing diff: " ++ err
        Right deltas -> return $ concatMap diffToHunks deltas
    source <- undefined
    return (hunks, source)

getReviewR :: PullRequest -> Handler Html
getReviewR pr = do
    (hunks, source) <- liftIO $ hunksForPR pr
    let fileparts = fillInContext source hunks
        diffLines isSrc lines = $(whamletFile "templates/diff-lines.hamlet")
        contextLines lines = $(whamletFile "templates/context-lines.hamlet")
    defaultLayout $ do
        setTitle $ toHtml $ "Reviewing " ++ show pr
        addScriptRemote "//code.jquery.com/jquery-2.1.1.min.js"
        $(widgetFile "review")