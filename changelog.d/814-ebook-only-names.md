### Internal
- **The e-book-only functions and test modules say `ebook` (#814).** The e-book indexer callbacks
  are now `search_ebook/3` and `search_ebook_query/2`, beside `search_audiobook/3` and
  `search_audiobook_query/2`, and the e-book import names its destination with
  `Cinder.Library.EbookNaming.ebook_dest/3`. Prowlarr receives the same e-book searches as before.
