{-# LANGUAGE BlockArguments #-}
-- {-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- {-# LANGUAGE ViewPatterns #-}

import ChaoDoc
import Data.Either
import Data.Functor
import qualified Data.Map as M
-- import Data.Maybe
import qualified Data.Text as T
import Hakyll
import System.IO.Unsafe
import Text.Pandoc
import Text.Pandoc.Citeproc
-- import Text.Pandoc.Walk (walkM)

root :: String
root = "https://talldoor.uk"
--------------------------------------------------------------------------------
main :: IO ()
main = hakyll $ do
  match "images/**" $ do
    route idRoute
    compile copyFileCompiler

  match "pdfs/**" $ do
    route idRoute
    compile copyFileCompiler

  match "includes/**" $ do  -- host some useful headers. wget xxx!
    route idRoute
    compile copyFileCompiler

  match "fonts/*" $ do
    route idRoute
    compile copyFileCompiler

  match "favicon.ico" $ do
    route idRoute
    compile copyFileCompiler

  match "css/*" $ do
    route idRoute
    compile compressCssCompiler

  match "about.md" $ do
    route $ setExtension "html"
    compile $
      chaoDocCompiler
        >>= loadAndApplyTemplate "templates/about.html" defaultContext
        >>= relativizeUrls
  match "404.md" $ do
    route $ setExtension "html"
    compile $
      chaoDocCompiler
        >>= loadAndApplyTemplate "templates/default.html" defaultContext
        >>= relativizeUrls

  -- build up tags
  tags <- buildTags "posts/*" (fromCapture "tags/*.html")
  tagsRules tags $ \tag pattern -> do
    let title = "Posts tagged \"" ++ tag ++ "\""
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll pattern
      let ctx =
            constField "title" title
              `mappend` listField "posts" (postCtxWithTags tags) (return posts)
              `mappend` defaultContext
      makeItem ""
        >>= loadAndApplyTemplate "templates/tag.html" ctx
        >>= loadAndApplyTemplate "templates/default.html" ctx
        >>= relativizeUrls

  match "posts/*" $ do
    route $ setExtension "html"
    compile $
      chaoDocCompiler
        >>= loadAndApplyTemplate "templates/post.html" (postCtxWithTags tags)
        >>= loadAndApplyTemplate "templates/default.html" (postCtxWithTags tags)
        >>= relativizeUrls
        >>= katexFilter

  create ["archive.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*"
      let archiveCtx =
            listField "posts" postCtx (return posts)
              `mappend` constField "title" "Archives"
              `mappend` defaultContext
      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
        >>= loadAndApplyTemplate "templates/default.html" archiveCtx
        >>= relativizeUrls

  create ["draft.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*"
      let archiveCtx =
            listField "posts" postCtx (return posts)
              `mappend` constField "title" "Drafts"
              `mappend` defaultContext
      makeItem ""
        >>= loadAndApplyTemplate "templates/draft.html" archiveCtx
        >>= loadAndApplyTemplate "templates/default.html" archiveCtx
        >>= relativizeUrls

  match "index.html" $ do
    route idRoute
    compile $ do
      posts <- fmap (take 25) . recentFirst =<< loadAll "posts/*"
      let indexCtx =
            listField "posts" postCtx (return posts)
              `mappend` defaultContext

      getResourceBody
        >>= applyAsTemplate indexCtx
        >>= loadAndApplyTemplate "templates/index.html" indexCtx
        >>= relativizeUrls

  match "templates/*" $ compile templateBodyCompiler
  -- https://robertwpearce.com/hakyll-pt-2-generating-a-sitemap-xml-file.html
  create ["sitemap.xml"] $ do
      route idRoute
      compile $ do
          posts <- recentFirst =<< loadAll "posts/*"
          singlePages <- loadAll (fromList ["about.md"])
          let pages = posts <> singlePages
              sitemapCtx =
                  constField "root" root <> -- here
                  listField "pages" postCtx (return pages)
          makeItem ""
              >>= loadAndApplyTemplate "templates/sitemap.xml" sitemapCtx

--------------------------------------------------------------------------------
postCtx :: Context String
postCtx =
  dateField "date" "%B %e, %Y"
  <> constField "root" root
  <> dateField "date" "%Y-%m-%d"
  <> defaultContext

postCtxWithTags :: Tags -> Context String
postCtxWithTags tags = tagsField "tags" tags `mappend` postCtx

-- pandocCompiler_ :: Compiler (Item String)
-- pandocCompiler_ =
--     let
--     mathExtensions =
--         [ Ext_tex_math_dollars
--         , Ext_tex_math_double_backslash
--         , Ext_latex_macros
--         , Ext_raw_tex
--         , Ext_raw_html
--         ]
--     newExtensions = foldr enableExtension defaultExtensions mathExtensions
--     defaultExtensions = writerExtensions defaultHakyllWriterOptions
--     writerOptions =
--         defaultHakyllWriterOptions
--         { writerExtensions = newExtensions
--         , writerHTMLMathMethod = KaTeX ""
--         }
--     in pandocCompilerWithTransformM defaultHakyllReaderOptions writerOptions pygmentsHighlight
--     where 
--       pygmentsHighlight :: Pandoc -> Compiler Pandoc
--       pygmentsHighlight = walkM \case
--         CodeBlock (_, listToMaybe -> mbLang, _) (T.unpack -> body) -> do
--           let lang = T.unpack (fromMaybe "text" mbLang)
--           RawBlock "html" . T.pack <$> callPygs lang body
--         block -> pure block
--         where
--           callPygs :: String -> String -> Compiler String
--           callPygs lang = unixFilter "pygmentize" [ "-l", lang
--                                                   , "-f", "html"
--                                                   , "-P", "cssclass=pygmentize-block"
--                                                   , "-P", "cssstyles=padding-left: 1em;"
--                                                   ]


katexFilter :: Item String -> Compiler (Item String)
katexFilter = withItemBody (unixFilter "./katex_cli" [])

-- copied from chao's site.hs for biblography
cslFile :: String
cslFile = "bib_style.csl"

bibFile :: String
bibFile = "reference.bib"

chaoDocCompiler :: Compiler (Item String)
chaoDocCompiler = do
  ( getResourceBody
      >>= myReadPandocBiblio chaoDocRead (T.pack cslFile) (T.pack bibFile) theoremFilter
    )
    <&> writePandocWith chaoDocWrite

addMeta :: T.Text -> MetaValue -> Pandoc -> Pandoc
addMeta name value (Pandoc meta a) =
  let prevMap = unMeta meta
      newMap = M.insert name value prevMap
      newMeta = Meta newMap
   in Pandoc newMeta a

myReadPandocBiblio ::
  ReaderOptions ->
  T.Text -> -- csl file name
  T.Text ->
  (Pandoc -> Pandoc) -> -- apply a filter before citeproc
  Item String ->
  Compiler (Item Pandoc)
myReadPandocBiblio ropt csl biblio filter item = do
  -- Parse CSL file, if given
  -- style <- unsafeCompiler $ CSL.readCSLFile Nothing . toFilePath . itemIdentifier $ csl

  -- We need to know the citation keys, add then *before* actually parsing the
  -- actual page. If we don't do this, pandoc won't even consider them
  -- citations!
  -- let Biblio refs = itemBody biblio
  pandoc <- itemBody <$> readPandocWith ropt item
  let pandoc' =
        fromRight pandoc $
          unsafePerformIO $
            runIO $
              processCitations $
                addMeta "bibliography" (MetaList [MetaString biblio]) $
                  addMeta "csl" (MetaString csl) $
                    addMeta "link-citations" (MetaBool True) $
                      addMeta "reference-section-title" (MetaInlines [Str "References"]) $
                        filter pandoc -- here's the change
                        -- let a x = itemSetBody (pandoc' x)
  return $ fmap (const pandoc') item
