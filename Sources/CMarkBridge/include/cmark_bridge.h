#ifndef CMARK_BRIDGE_H
#define CMARK_BRIDGE_H

#include "cmark.h"

// GFM extension functions not exported by the cmark module's public headers.
// These symbols exist in the compiled cmark library.
extern void cmark_gfm_core_extensions_ensure_registered(void);
extern cmark_syntax_extension *cmark_find_syntax_extension(const char *name);
extern int cmark_parser_attach_syntax_extension(cmark_parser *parser, cmark_syntax_extension *extension);
extern cmark_llist *cmark_parser_get_syntax_extensions(cmark_parser *parser);

#endif
