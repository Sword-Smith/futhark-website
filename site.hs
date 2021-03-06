{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Main (main) where

import           Control.Monad
import           Data.Monoid ((<>))
import           Data.List (isPrefixOf)
import qualified Data.Map as M
import           System.FilePath
import           Hakyll
import           Skylighting (Syntax, parseSyntaxDefinition)
import           Text.Pandoc
import           Text.Pandoc.Walk
import qualified Data.Text as T

postCtx :: Context String
postCtx = mconcat
  [ modificationTimeField "mtime" "%U"
  , dateField "date" "%B %e, %Y"
  , defaultContext
  ]

static :: Rules ()
static = void $ route idRoute >> compile copyFileCompiler

-- Turn a Futhark program into Markdown.
weave :: String -> String
weave = unlines . map onLine . lines
  where isText = isPrefixOf "--"
        onLine l | isText l = drop 3 l
                 | otherwise = "    " ++ l

main :: IO ()
main = do
  futhark_syntax <- either (error . show) return =<<
                    parseSyntaxDefinition "skylighting/futhark.xml"
  hakyllWith config $ do
    match "images/*" static

    match "robots.txt" static

    match "static/*" static

    match "publications/*" static

    match "student-projects/*" static

    match "benchmarks/programs/*" static

    match "css/*" $ do
        route idRoute
        compile compressCssCompiler

    match (fromList ["performance.rst",
                     "docs.rst",
                     "getinvolved.rst",
                     "index.rst",
                     "examples.rst"]) $ do
        route $ setExtension "html"
        compile $ do
          menu <- contentContext
          pandocRstCompiler futhark_syntax
            >>= loadAndApplyTemplate "templates/withtitle.html" menu
            >>= loadAndApplyTemplate "templates/default.html" menu
            >>= relativizeUrls

    match "blog/*" $ do
        route $ setExtension "html"
        compile $ do
          postCtx' <- postContext
          pandocRstCompiler futhark_syntax
            >>= loadAndApplyTemplate "templates/post.html"    postCtx'
            >>= saveSnapshot "content"
            >>= loadAndApplyTemplate "templates/withtitle.html" postCtx'
            >>= loadAndApplyTemplate "templates/default.html" postCtx'
            >>= relativizeUrls

    -- Post list
    create ["blog.html"] $ do
        route idRoute
        compile $ do
            menu <- getMenu
            posts <- recentFirst =<< loadAll "blog/*"
            let ctx = constField "title" "Developer Blog" <>
                      listField "posts" postCtx (return posts) <>
                      constField "menu" menu <>
                      defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/posts.html" ctx
                >>= loadAndApplyTemplate "templates/withtitle.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx
                >>= relativizeUrls

    -- Atom feed
    create ["atom.xml"] $ do
      route idRoute
      compile $ do
        let feedCtx = postCtx `mappend` bodyField "description"
        posts <- fmap (take 10) . recentFirst =<<
            loadAllSnapshots "blog/*" "content"
        renderAtom feedConfiguration feedCtx posts

    -- Examples
    match "examples/*.fut" $ do
      route $ setExtension "html"
      compile $ do
        menu <- contentContext
        (ctx, md) <- literateCompiler futhark_syntax
        pure md
          >>= saveSnapshot "content"
          >>= loadAndApplyTemplate "templates/default.html" (ctx <> menu)
          >>= relativizeUrls
    match "examples/*.fut" $ version "source" static

    match "templates/*" $ compile templateCompiler

contentContext :: Compiler (Context String)
contentContext = do
  menu <- getMenu
  return $
    defaultContext `mappend`
    constField "menu" menu

getMenu :: Compiler String
getMenu = do
  myRoute <- getRoute =<< getUnderlying
  return $ case myRoute of
             Nothing -> showMenu "" menuContents
             Just me -> showMenu me menuContents

menuContents :: [(String, FilePath)]
menuContents = [("Overview", "index.html"),
                ("Examples", "examples.html"),
                ("Docs", "docs.html"),
                ("Gotta Go Fast!", "performance.html"),
                ("Get Involved", "getinvolved.html"),
                ("Blog", "blog.html")]

showMenu :: FilePath -> [(String, FilePath)] -> String
showMenu this items = "<ul id=\"menu\">"++concatMap li items++"</ul>"
  where li (name, item)
          | isThis item = "<li id=\"chosen\"><a href=\"/"++item++"\">"++name++"</a></li>"
          | otherwise   = "<li><a href=\"/"++item++"\">"++name++"</a></li>"
        isThis item = dropExtension item `isPrefixOf` dropExtension this

--------------------------------------------------------------------------------
postContext :: Compiler (Context String)
postContext = do
  ctx <- contentContext
  return $ dateField "date" "%B %e, %Y" `mappend` ctx

--------------------------------------------------------------------------------

-- | By default, RST will make all top-level titles <h1>s, but we
-- prefer to only have a single <h1>: the one in the template.  We use
-- a technique from
-- http://maxdelgiudice.com/posts/2015-07-08-rst-headers.html to avoid
-- this.
shiftHeaderUp :: Block -> Block
shiftHeaderUp h@(Header n a b)
    | n < 6     = Header (n+1) a b
    | otherwise = h
shiftHeaderUp x = x

-- | All headers should be links to themselves.
selfLinkHeader :: Block -> Block
selfLinkHeader (Header n (ident, classes, kvs) b) =
  Header n (ident, classes, kvs) [b']
  where b' = Link (ident <> "-link", ["titlelink"], []) b ('#' : ident, ident)
selfLinkHeader x = x

pandocOptions :: Syntax -> (ReaderOptions, WriterOptions)
pandocOptions futhark_syntax =
  (defaultHakyllReaderOptions { readerIndentedCodeClasses = ["Futhark"] },
   defaultHakyllWriterOptions { writerSyntaxMap = syntaxmap })
  where syntaxmap = M.insert "Futhark" futhark_syntax $
                    writerSyntaxMap defaultHakyllWriterOptions

pandocRstCompiler :: Syntax -> Compiler (Item String)
pandocRstCompiler futhark_syntax =
  pandocCompilerWithTransform ropts wopts $
  walk (selfLinkHeader . shiftHeaderUp)
  where (ropts, wopts) = pandocOptions futhark_syntax

literateCompiler :: Syntax -> Compiler (Context String, Item String)
literateCompiler futhark_syntax = do
  s <- fmap (T.pack . weave) <$> getResourceBody
  pandoc@(Item _ (Pandoc _ (Header _ _ title:_))) <-
    case runPure $ traverse (readMarkdown ropts) s of
      Left err -> error $ "literateCompiler: " ++ show err
      Right s' -> return s'
  case runPure $ writePlain wopts $ Pandoc mempty [Plain title] of
    Left err -> error $ "literateCompiler: " ++ show err
    Right title' ->
      return (constField "title" $ T.unpack title',
              writePandocWith wopts pandoc)
  where (ropts, wopts) = pandocOptions futhark_syntax

--------------------------------------------------------------------------------
config :: Configuration
config = defaultConfiguration
  { deployCommand = "rsync --chmod=Do+rx,Fo+r --checksum -ave 'ssh -p 22' \
                     \_site/* --exclude pub futhark@sigkill.dk:/var/www/htdocs/futhark-lang.org"
  }

feedConfiguration :: FeedConfiguration
feedConfiguration = FeedConfiguration
    { feedTitle       = "Futhark Developer Blog"
    , feedDescription = "High-performance purely functional data-parallel array programming on the GPU"
    , feedAuthorName  = "Troels Henriksen"
    , feedAuthorEmail = "athas@sigkill.dk"
    , feedRoot        = "http://futhark-lang.org"
    }
