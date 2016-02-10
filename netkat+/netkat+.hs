import System.Environment
import Text.Parsec.Prim
import Control.Monad
import qualified Data.Map as M
import System.FilePath.Posix
import Text.PrettyPrint
import Data.Maybe
import Data.List
import System.Directory

import Parse
import Validate
import P4.P4
import Syntax
import Pos
import NS
import Name
import Topology
import MiniNet.MiniNet
import qualified SMT.SMTSolver as SMT
import qualified SMT.SMTLib2   as SMT


main = do
    args <- getArgs
    prog <- getProgName
    when (length args /= 1) $ fail $ "Usage: " ++ prog ++ " <file>"
    let fname = head args
        (dir, file) = splitFileName fname
        (basename,_) = splitExtension file
        workdir = dir </> basename
    createDirectoryIfMissing False workdir
    fdata <- readFile fname
    spec <- case parse nkplusGrammar fname fdata of
                 Left  e    -> fail $ "Failed to parse input file: " ++ show e
                 Right spec -> return spec
    combined <- case validate spec of
                      Left e   -> fail $ "Validation error: " ++ e
                      Right rs -> return rs
    let final = last combined
    putStrLn "Validation successful"

    let fmap = M.fromList [("k", EInt nopos 8 2), ("netmask", EInt nopos 8 10)]
        topology = generateTopology final fmap
        (mntopology, instmap) = generateMininetTopology final topology
        p4switches = genP4Switches final fmap topology
    writeFile (workdir </> addExtension basename "mn") mntopology
    mapM (\(descr, (p4,cmd)) -> do let swname = snd $ fromJust $ find ((==descr) . fst) instmap
                                   writeFile (workdir </> addExtension (addExtension basename swname) "p4")  (render p4)
                                   writeFile (workdir </> addExtension (addExtension basename swname) "txt") (render cmd)) 
         p4switches
    return ()


--    let kmap = M.fromList [("hash", EInt nopos 1), ("hash2", EInt nopos 1)]
--        pmap = M.fromList [("CoreIn", (0,3)), ("CoreOut", (0,3))]
--    let (p4, command) = genP4Switch final (getNode final "CoreSwitch") fmap kmap pmap
--    writeFile (addExtension (addExtension basename "core") "p4") (render p4) 
--    writeFile (addExtension (addExtension basename "core") "txt") (render command) 
--
--    let kmap = M.fromList [("subnet", EInt nopos 1), ("subsubnet", EInt nopos 1)]
--        pmap = M.fromList [("PodeLowerUIn", (0,1)), ("PodLowerUOut", (0,1)), ("PodLowerLIn", (2,3)), ("PodLowerLOut", (2,3))]
--    let (p4, command) = genP4Switch final (getNode final "PodLowerSwitch") fmap kmap pmap
--    writeFile (addExtension (addExtension basename "lower") "p4") (render p4) 
--    writeFile (addExtension (addExtension basename "lower") "txt") (render command) 
--
--    let kmap = M.fromList [("subnet", EInt nopos 1), ("hash", EInt nopos 0)]
--        pmap = M.fromList [("PodeUpperUIn", (0,1)), ("PodUpperUOut", (0,1)), ("PodUpperLIn", (2,3)), ("PodUpperLOut", (2,3))]
--    let (p4, command) = genP4Switch final (getNode final "PodUpperSwitch") fmap kmap pmap
--    writeFile (addExtension (addExtension basename "upper") "p4") (render p4) 
--    writeFile (addExtension (addExtension basename "upper") "txt") (render command) 
