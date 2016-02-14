" A lint tool for vim help files.
" Maintainer:  Masaaki Nakamura <mckn{at}outlook.jp>
" Last Change: 13-Feb-2016.
" License:     NYSL license
"              Japanese <http://www.kmonos.net/nysl/>
"              English (Unofficial) <http://www.kmonos.net/nysl/index.en.html>

" NOTE: Usage when you edit a vim help file, type:
"           :VimhelpLint<CR>
"       Or if you add bang '!', then it opens quickfix window if there were
"       error.
"           :VimhelpLint!<CR>

" NOTE: Error list
"       1 : Warning : The width of a line should be no longer than 78.
"       2 :  Error  : Duplicate tags in the same file.
"       3 :  Error  : Duplicate tags in another file.
"       4 :  Error  : A hot link is not linked to any tags.
"       5 : Warning : A hot link seems mis-typed.
"       6 : Warning : A tag seems to have inconsistency with a link on scope prefix.

if &compatible || exists('b:loaded_ftplugin_help_lint')
  finish
endif
let b:loaded_ftplugin_help_lint = 1

command! -bang -buffer -bar -nargs=0 VimhelpLint call s:vimhelp_lint('<bang>')

if exists("*\<SID>vimhelp_lint")
  finish
endif

" patches
if v:version > 704 || (v:version == 704 && has('patch237'))
  let s:has_patch_7_4_218 = has('patch-7.4.218')
  let s:has_patch_7_4_358 = has('patch-7.4.358')
else
  let s:has_patch_7_4_218 = v:version == 704 && has('patch218')
  let s:has_patch_7_4_358 = v:version == 704 && has('patch358')
endif

function! s:vimhelp_lint(bang) abort "{{{
  " NOTE: Error number list
  "         1: A duplicate tag within this file
  "         2: A duplicate tag with another file

  if &filetype !=# 'help'
    call s:echo('This is not a help file!', 'ErrorMsg')
    return
  endif

  let qflist = []

  """ gather hyper texts
  let view      = s:winsaveview()
  let separator = has('win32') && !&shellslash ? '\' : '/'
  let path_expr = printf('%s%s*.%s', expand('%:h'), separator, expand('%:e'))
  let hypertext_in_files = []
  for doc in glob(path_expr, 1, 1)
    let bufnr = bufnr(doc, !bufexists(doc))
    let hypertext_in_files += s:extract_hypertexts(bufnr)
    let qflist += map(range(1, line('$')), 's:checker_for_style(v:val, bufnr)')
  endfor
  call s:winrestview(view)

  """ clasify
  let tags_in_files  = filter(copy(hypertext_in_files), 'v:val.kind ==# "tag"')
  let links_in_files = filter(copy(hypertext_in_files), 'v:val.kind ==# "link"')

  """ check
  let taglist = map(copy(tags_in_files), 'v:val.name')
  let buftype = &l:buftype
  try
    let &l:buftype = 'help'

    " check tags : A tag should not be duplicate.
    let qflist += s:check(tags_in_files, function('s:checker_for_tags'), taglist)

    " check links : A link should have a corresponding tag.
    let qflist += s:check(links_in_files, function('s:checker_for_links'), taglist)
  finally
    let &l:buftype = buftype
  endtry
  call s:sort(filter(qflist, 'v:val != {}'), 's:compare_qfitems')

  call setqflist(qflist, 'r')
  if qflist != []
    if a:bang ==# '!'
      copen
    endif
    call s:hier('on')
    call s:echo(printf('%d errors have been found!', len(qflist)), 'WarningMsg')
  else
    call s:hier('off')
    call s:echo('No errors.')
  endif
endfunction
"}}}
function! s:extract_hypertexts(bufnr) abort  "{{{
  execute 'buffer ' . a:bufnr

  let hypertext_in_files = []
  let lines   = getline(1, line('$'))
  let skip    = 0
  let scraped = []
  for [lnum, line] in map(range(1, line('$')), '[v:val, lines[v:val-1]]')
    if skip
      if line =~# '^\%([^ [:tab:]]\|<\)'
        let skip = 0
      endif
    endif

    if !skip
      let scraped += s:extract_hypertexts_from_a_line(lnum, line)

      if line =~# '\%(^\| \)>$'
        let skip = 1
      endif
    endif
  endfor

  let buf_info = {'bufnr': a:bufnr, 'bufname': fnamemodify(bufname('%'), ':t:r')}
  let hypertext_in_files += map(scraped, 'extend(v:val, buf_info)')

  return hypertext_in_files
endfunction
"}}}
function! s:extract_hypertexts_from_a_line(lnum, line) abort  "{{{
  let list = []

  " extract tags
  let list += s:extract_a_kind_of_hypertexts(a:lnum, a:line, 'tag', '\*\zs[#-)!+-{}~]\+\ze\*\%(\s\|$\)')

  " extract links
  let list += s:extract_a_kind_of_hypertexts(a:lnum, a:line, 'link', '\%(^\|[^\\]\)|\zs[#-)!+-{}~]\+\ze|', '\%(|||\|.*====*|\|:|vim:|\)')

  " extract options as link
  let list += s:extract_a_kind_of_hypertexts(a:lnum, a:line, 'link', '\C''\%([a-z]\{2,}\|t_..\)''', '\s*\zs.\{-}\ze\s\=\~$')

  return list
endfunction
"}}}
function! s:extract_a_kind_of_hypertexts(lnum, line, kind, pattern, ...) abort  "{{{
  let exceptpat = get(a:000, 0, '')
  let list = []
  let l:count = 1
  while 1
    " NOTE: Use same arguments for match() and matchstr() because its faster.
    "       A kind of cache might take effect(?)
    let start = match(a:line, a:pattern, 0, l:count)
    if start > -1
      let str = matchstr(a:line, a:pattern, 0, l:count)
      if exceptpat ==# '' || !s:is_except_pattern(a:line, exceptpat, start)
        let list += [{'kind': a:kind, 'name': str, 'lnum': a:lnum, 'start': start}]
      endif
    else
      break
    endif
    let l:count += 1
  endwhile
  return list
endfunction
"}}}
function! s:is_except_pattern(line, exceptpat, idx) abort "{{{
  let result  = 0
  let l:count = 1
  while 1
    let except_start = match(a:line, a:exceptpat, 0, l:count)
    let except_end   = matchend(a:line, a:exceptpat, 0, l:count)
    if except_start < 0 || except_end < 0
      break
    elseif a:idx >= except_start && a:idx < except_end
      let result = 1
      break
    endif
    let l:count += 1
  endwhile
  return result
endfunction
"}}}
function! s:escape(string) abort  "{{{
  return escape(a:string, '~"\.^$[]*')
endfunction
"}}}
function! s:winsaveview() abort "{{{
  return [bufnr('%'), winsaveview()]
endfunction
"}}}
function! s:winrestview(view) abort "{{{
  let [bufnr, view] = a:view
  execute 'buffer ' . bufnr
  call winrestview(view)
endfunction
"}}}
function! s:hier(switch) abort  "{{{
  if a:switch ==# 'on'
    if exists(':HierUpdate')
      if !exists('g:hier_enabled')
        HierStart
      else
        HierUpdate
      endif
    endif
  elseif a:switch ==# 'off'
    if exists('g:hier_enabled')
      " FIXME: Which is better? HierStop or HierClear?
      HierStop
    endif
  endif
endfunction
"}}}
function! s:echo(str, ...) abort "{{{
  let hl = get(a:000, 0, 'NONE')
  execute 'echohl ' . hl
  echo 'vimhelplint: ' . a:str
  echohl NONE
endfunction
"}}}

" checkers
function! s:check(targets, checker, taglist) abort "{{{
  " NOTE: The returned should be same as
  "       filter(map(copy(a:targets), 'a:checker(v:val, a:taglist)'), 'v:val != {}')
  "       but faster because removing duplicates.
  let representatives = uniq(sort(deepcopy(a:targets), 's:compare_bufnr_and_name'), 's:compare_bufnr_and_name')
  let qflist  = []
  for rep in representatives
    let result = a:checker(rep, a:taglist)
    if result != {}
      for target in a:targets
        if rep.name ==# target.name && rep.bufnr == target.bufnr
          let nr    = result.nr
          let type  = result.type
          let bufnr = target.bufnr
          let lnum  = target.lnum
          let idx   = target.start
          let text  = result.text
          let qflist += [s:qfitem(nr, type, bufnr, lnum, idx, text)]
        endif
      endfor
    endif
  endfor
  return qflist
endfunction
"}}}
function! s:checker_for_style(lnum, bufnr) abort "{{{
  let qfitem = {}
  if strdisplaywidth(getline(a:lnum)) > 78
    let text = 'The width of a line should be no longer than 78.'
    let qfitem = s:qfitem(1, 'W', a:bufnr, a:lnum, 1, text)
  endif
  return qfitem
endfunction
"}}}
function! s:checker_for_tags(tag, taglist) abort "{{{
  let name    = a:tag.name
  let bufnr   = a:tag.bufnr
  let bufname = a:tag.bufname
  let lnum    = a:tag.lnum
  let idx     = a:tag.start

  let qfitem = {}
  if count(a:taglist, name, 0) > 1
    " [Error 2]
    let text = printf('A tag "%s" is duplicate with another in this file.', name)
    let qfitem = s:qfitem(2, 'E', bufnr, lnum, idx, text)
  else
    let pattern = printf('\C^%s$', s:escape(name))
    let tags_in_external_file = taglist(pattern)
    for ext_tag in tags_in_external_file
      if fnamemodify(ext_tag.filename, ':t:r') !=? bufname
        " [Error 3]
        let text = printf('A tag "%s" is duplicate with another in the file %s.', name, ext_tag.filename)
        let qfitem = s:qfitem(3, 'E', bufnr, lnum, idx, text)
        break
      endif
    endfor
  endif
  return qfitem
endfunction
"}}}
function! s:checker_for_links(link, taglist) abort  "{{{
  let bufnr   = a:link.bufnr
  let bufname = a:link.bufname
  let lnum    = a:link.lnum
  let idx     = a:link.start

  let qfitem = {}
  if count(a:taglist, a:link.name, 0) < 1
    let is_linked = 0

    let pattern = printf('\C^%s$', s:escape(a:link.name))
    let tags_in_external_file = taglist(pattern)
    if tags_in_external_file != []
      for ext_tag in tags_in_external_file
        if fnamemodify(ext_tag.filename, ':t:r') !=? bufname
          let is_linked = 1
          break
        endif
      endfor
    else
      let is_linked = 0
    endif

    if !is_linked
      " analogize
      " FIXME: It might be unnecessary.
      let likely = s:analogize(a:link, a:taglist)

      if likely == {}
        " [Error 4]
        let likely = s:analogize(a:link, a:taglist, 1)
        if likely == {}
          let text = printf('A link "%s" does not have a corresponding tag.', a:link.name)
        else
          let text = printf('A link "%s" does not have a corresponding tag. Isn''t it "%s"?', a:link.name, likely.name)
        endif
        let qfitem = s:qfitem(4, 'E', bufnr, lnum, idx, text)
      else
        if get(likely, 'error', 4) == 4
          " [Error 5]
          let text = printf('A link "%s" does not have a corresponding tag. Isn''t it "%s"?', a:link.name, likely.name)
          let qfitem = s:qfitem(5, 'W', bufnr, lnum, idx, text)
        else
          " [Error 6]
          let text = printf('There is a tag "%s". Is it consistent with a link "%s"?', likely.name, a:link.name)
          let qfitem = s:qfitem(6, 'W', bufnr, lnum, idx, text)
        endif
      endif
    endif
  endif
  return qfitem
endfunction
"}}}
function! s:qfitem(nr, type, bufnr, lnum, col, text) abort  "{{{
  return {
       \   'nr'    : a:nr,
       \   'type'  : a:type,
       \   'bufnr' : a:bufnr,
       \   'lnum'  : a:lnum,
       \   'col'   : a:col,
       \   'vcol'  : 0,
       \   'text'  : a:text,
       \ }
endfunction
"}}}
function! s:analogize(link, taglist, ...) abort "{{{
  let escaped = s:escape(a:link.name)
  if !get(a:000, 0, 0)
    " assume the link as a name of a valiable without a scope prefix
    if a:link.name =~# '^[bgtw]:\h[[:alnum:]_#]\{2,}$'
      let pattern = printf('^%s$', escaped[2:])
      let idx = match(a:taglist, pattern)
      if idx > -1
        return {'name': a:taglist[idx], 'error': 5}
      endif
    endif

    " simplely analogize
    if a:link.name =~# '^\h\%(\w\+[_#]\)\+\w\+\%(()\)\?$'
      let pattern = printf('^[bgtw]:%s\%(()\)\?$', escaped)
    elseif a:link.name =~# '^\h\w*$'
      let pattern = printf('^\%(:\?%s\|%s()\|''%s''\|%s.*\|.*%s\)$', escaped, escaped, escaped, escaped, escaped)
    else
      let pattern = printf('%s', escaped)
    endif
  else
    " deeply analogize
    if a:link.name =~# '''^[:alpha:]\{2,}$'''
      let word = matchstr(a:link.name, '''\zs[:alpha:]\{2,}\ze''')
      let pattern = printf('''%s''', s:fuzzy_pattern(word))
    elseif a:link.name =~# '^\h\w*()$'
      let word = matchstr(a:link.name, '\h\w*\ze()')
      let pattern = printf('%s()', s:fuzzy_pattern(word))
    elseif a:link.name =~# '^:\h\w*$'
      let word = matchstr(a:link.name, ':\h\w*\ze')
      let pattern = printf(':%s', s:fuzzy_pattern(word))
    elseif a:link.name =~# '^\h\w*$'
      let fuzzy_pattern = s:fuzzy_pattern(a:link.name)
      let pattern = printf('^\%(:\?%s\|%s()\|''%s''\|%s.*\)$', fuzzy_pattern, fuzzy_pattern, fuzzy_pattern, escaped)
    else
      let pattern = s:fuzzy_pattern(a:link.name)
    endif
  endif

  let errormsg = ''
  try
    let idx = match(a:taglist, pattern)
  catch /^Vim\%((\a\+)\)\=:E16/
    " backtrack too complicated pattern
    let pattern = printf('\%%(%s.\|%s\)', escaped, escaped[0:-2])
    let idx = match(a:taglist, pattern)
  catch
    let errormsg = printf('vimhelplint: Unanticipated error. [%s] %s', v:throwpoint, v:exception)
  finally
    if errormsg ==# ''
      if idx > -1
        let likely = {'name': a:taglist[idx]}
      else
        let likely = get(taglist(pattern), 0, {})
        if get(likely, 'name', '') ==# a:link.name
          " NOTE: I don't know why but taglist() returns a non-existent tag
          "       (probably when a same named link exists).
          let likely = {}
        endif
      endif
    else
      echoerr errormsg
    endif
    return likely
  endtry
endfunction
"}}}
function! s:fuzzy_pattern(word) abort "{{{
  " FIXME: Ah... Does anyone have good idea?

  let charlist = map(split(a:word, '\zs'), 's:escape(v:val)')

  " swapped
  let items = []
  if len(charlist) > 1
    for n in range(len(charlist)-1)
      let copied = copy(charlist)
      let c = remove(copied, n)
      call insert(copied, c, n+1)
      let items += [join(copied, '')]
    endfor
  endif
  let swapped = join(items, '\|')

  " misspelled
  let items = []
  if len(charlist) > 1
    for n in range(len(charlist))
      let copied = copy(charlist)
      let copied[n] = '.'
      let items += [join(copied, '')]
    endfor
  endif
  let misspelled = join(items, '\|')

  " dropped
  let items = []
  for n in range(len(charlist))
    let copied = copy(charlist)
    call remove(copied, n)
    let items += [join(copied, '')]
  endfor
  let dropped = join(items, '\|')

  " added
  let items = []
  for n in range(len(charlist))
    let copied = copy(charlist)
    call insert(copied, '.', n)
    let items += [join(copied, '')]
  endfor
  let copied = copy(charlist)
  let items += [join(add(copied, '.'), '')]
  let added = join(items, '\|')

  return printf('\%%(%s\)', join([swapped, misspelled, dropped, added], '\|'))
endfunction
"}}}
" function! s:sort(list, func, ...) abort  "{{{
if s:has_patch_7_4_358
  function! s:sort(list, func, ...) abort
    return sort(a:list, a:func)
  endfunction
else
  function! s:sort(list, func, ...) abort
    " NOTE: len(a:list) is always larger than n or same.
    " FIXME: The number of item in a:list would not be large, but if there was
    "        any efficient argorithm, I would rewrite here.
    let len = len(a:list)
    let n = min([get(a:000, 0, len), len])
    for i in range(n)
      if len - 2 >= i
        let min = len - 1
        for j in range(len - 2, i, -1)
          if call(a:func, [a:list[min], a:list[j]]) >= 1
            let min = j
          endif
        endfor

        if min > i
          call insert(a:list, remove(a:list, min), i)
        endif
      endif
    endfor
    return a:list
  endfunction
endif
"}}}
" function! s:uniq(list, func) abort  "{{{
if s:has_patch_7_4_218
  function! s:uniq(list, func) abort
    return uniq(a:list, a:func)
  endfunction
else
  function! s:uniq(list, func) abort
    let len = len(a:list)
    if len > 1
      let i = 0
      while i < len-1
        if call(a:func, [a:list[i], a:list[i+1]]) == 0
          call remove(a:list[i+1])
        else
          let i += 1
        endif
      endwhile
    endif
    return a:list
  endfunction
endif
"}}}
function! s:compare_bufnr_and_name(i1, i2) abort  "{{{
  if a:i1.bufnr != a:i2.bufnr
    let result = a:i1.bufnr - a:i2.bufnr
  else
    let result = s:compare_string(a:i1.name, a:i2.name)
  endif
  return result
endfunction
"}}}
function! s:compare_qfitems(i1, i2) abort "{{{
  if a:i1.bufnr != a:i2.bufnr
    let result = s:compare_string(bufname(a:i1.bufnr), bufname(a:i2.bufnr))
  else
    let pos1 = [a:i1.lnum, a:i1.col]
    let pos2 = [a:i2.lnum, a:i2.col]
    if s:is_ahead(pos1, pos2)
      let result = 1
    elseif s:is_ahead(pos2, pos1)
      let result = -1
    else
      let result = 0
    endif
  endif
  return result
endfunction
"}}}
function! s:compare_string(s1, s2) abort  "{{{
  let chars1 = map(split(a:s1, '\zs'), 'char2nr(v:val)')
  let chars2 = map(split(a:s2, '\zs'), 'char2nr(v:val)')
  let len1   = len(chars1)
  let len2   = len(chars2)
  let result = len1 - len2
  for i in range(min([len1, len2]))
    if chars1[i] != chars2[i]
      let result = chars1[i] - chars2[i]
      break
    endif
  endfor
  return result
endfunction
"}}}
function! s:is_ahead(pos1, pos2) abort  "{{{
  return a:pos1[0] > a:pos2[0] || (a:pos1[0] == a:pos2[0] && a:pos1[1] > a:pos2[1])
endfunction
"}}}

" vim:set foldmethod=marker:
" vim:set commentstring="%s:
" vim:set ts=2 sts=2 sw=2 et:
