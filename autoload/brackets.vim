fu brackets#di_list(cmd, search_cur_word, start_at_cursor, search_in_comments, ...) abort "{{{1
    " Derive the commands used below from the first argument.
    let excmd   = a:cmd..'list'..(a:search_in_comments ? '!' : '')
    let normcmd = toupper(a:cmd)

    " if we call the function from a normal mode mapping, the pattern is the
    " word under the cursor
    if a:search_cur_word
        " `silent!` because pressing `]I` on a unique word raises `E389`
        let output = execute('norm! '..(a:start_at_cursor ? ']' : '[')..normcmd, 'silent!')
        let title  = (a:start_at_cursor ? ']' : '[')..normcmd

    else
        " otherwise if the function was called with a fifth optional argument,
        " by one of our custom Ex command, use it as the pattern
        if a:0 > 0
            let pat = a:1
        else
            " otherwise the function must have been called from visual mode
            " (visual mapping): use the visual selection as the pattern
            let cb_save  = &cb
            let sel_save = &sel
            let reg_save = ['"', getreg('"'), getregtype('"')]
            try
                set cb-=unnamed cb-=unnamedplus
                set sel=inclusive
                norm! gvy
                let pat = substitute('\V'..escape(getreg('"'), '\/'), '\\n', '\\n', 'g')
                "                     │                                │{{{
                "                     │                                └ make sure newlines are not
                "                     │                                  converted into NULs
                "                     │                                  on the search command-line
                "                     │
                "                     └ make sure the contents of the pattern is interpreted literally
                "}}}
            finally
                let &cb  = cb_save
                let &sel = sel_save
                call call('setreg', reg_save)
            endtry
        endif

        let output = execute((a:start_at_cursor ? '+,$' : '')..excmd..' /'..pat, 'silent!')
        let title  = excmd..' /'..pat
    endif

    let lines = split(output, '\n')
    " Bail out on errors. (bail out = se désister)
    if get(lines, 0, '') =~ '^Error detected\|^$'
        echom 'Could not find '..string(a:search_cur_word ? expand('<cword>') : pat)
        return
    endif

    " Our results may span multiple files so we need to build a relatively
    " complex list based on filenames.
    let filename   = ''
    let ll_entries = []
    for line in lines
        " A line in the output of `:ilist` and `dlist` can be a filename.
        " It happens when there are matches in other included files.
        " It's how `:ilist` / `:dlist`tells us in which files are the
        " following entries.
        "
        " When we find such a line, we don't parse its text to add an entry
        " in the ll, as we would do for any other line.
        " We use it to update the variable `filename`, which in turn is used
        " to generate valid entries in the ll.
        if line !~ '^\s*\d\+:'
            let filename = fnamemodify(line, ':p:.')
        "                                      │ │{{{
        "                                      │ └ relative to current working directory
        "                                      └ full path
        "}}}
        else
            let lnum = split(line)[1]

            " remove noise from the text output:
            "
            "    1:   48   line containing pattern
            " ^__________^
            "     noise

            let text = substitute(line, '^\s*\d\{-}\s*:\s*\d\{-}\s', '', '')

            let col  = match(text, a:search_cur_word ? '\C\<'..expand('<cword>')..'\>' : pat) + 1
            call add(ll_entries,
            \ { 'filename' : filename,
            \   'lnum'     : lnum,
            \   'col'      : col,
            \   'text'     : text,
            \ })
        endif
    endfor

    call setloclist(0, [], ' ', {'items': ll_entries, 'title': title})

    " Populating the location list doesn't fire any event.
    " Fire `QuickFixCmdPost`, with the right pattern (*), to open the ll window.
    "
    " (*) `lvimgrep`  is a  valid pattern (`:h  QuickFixCmdPre`), and  it begins
    " with a `l`.   The autocmd that we  use to automatically open  a qf window,
    " relies on  the name  of the  command (how its  name begins),  to determine
    " whether it must open the ll or qfl window.
    do <nomodeline> QuickFixCmdPost lwindow
    if &bt isnot# 'quickfix' | return | endif

    " hide location
    call qf#set_matches('brackets:di_list', 'Conceal', 'location')
    call qf#create_matches()
endfu

fu brackets#mv_line(_) abort "{{{1
    let cnt = v:count1

    " disabling the folds may alter the view, so save it first
    let view = winsaveview()

    " Why do you disable folding?{{{
    "
    " We're going to do 2 things:
    "
    "    1. move a / several line(s)
    "    2. update its / their indentation
    "
    " If we're inside a fold, the `:move` command will close it.
    " Why?
    " Because of patch `7.4.700`. It solves one problem related to folds, and
    " creates a new one:
    " https://github.com/vim/vim/commit/d5f6933d5c57ea6f79bbdeab6c426cf66a393f33
    "
    " Then, it gets worse: because the fold is now closed, the indentation
    " command will indent the whole fold, instead of the line(s) on which we
    " were operating.
    "
    " MWE:
    "
    "     echo "fold\nfoo\nbar\nbaz\n" >file
    "     vim -Nu NONE file
    "     :set fdm=marker
    "     VGzf
    "     zv
    "     j
    "     :m + | norm! ==
    "     5 lines indented ✘ it should be just one~
    "
    " Maybe we could use `norm! zv` to open the folds, but it would be tedious
    " and error-prone in the future. Every time we would add a new command, we
    " would have to remember to use `norm! zv`. It's better to temporarily disable
    " folding entirely.
    "
    " Remember:
    " Because of a quirk of Vim's implementation, always temporarily disable
    " 'fen' before moving lines which could be in a fold.
    "}}}
    let [fen_save, winid, bufnr] = [&l:fen, win_getid(), bufnr('%')]
    let &l:fen = 0
    try
        " Why do we mark the line since we already saved the view?{{{
        "
        " Because,  after  the restoration  of  the  view,  the cursor  will  be
        " positioned on the old address of the line we moved.
        " We don't want that.
        " We want  the cursor to be  positioned on the same  line, whose address
        " has  changed. We can't  rely on  an address,  so we  need to  mark the
        " current line. The mark will follow the moved line, not an address.
        "}}}
        if has('nvim')
            " set an extended mark on current location before moving, so that we
            " can use the info later to restore the cursor position
            " Why not simply using a regular mark?{{{
            "
            " Even if you save and restore the original position of the mark, it
            " will be altered after an undo.
            "
            " MWE:
            "
            "     nno cd :call Func()<cr>
            "     fu Func() abort
            "         let z_save = getpos("'z")
            "         norm! mz
            "         m -1-
            "         norm! `z
            "         call setpos("'z", z_save)
            "     endfu
            "
            "     " put the mark `z` somewhere, hit `cd` somewhere else, undo,
            "     " then hit `z (the `z` mark has moved; we don't want that)
            "
            " The issue  comes from  the fact  that Vim saves  the state  of the
            " buffer right  before a  change. Here the change  is caused  by the
            " `:move`  command. So, Vim  saves  the state  of  the buffer  right
            " before `:m`, and thus with the `z` mark in the wrong and temporary
            " position.
            "}}}
            let ns_id = nvim_create_namespace('tempmark')
            let id = nvim_buf_set_extmark(0, ns_id, 0, line('.')-1, col('.'), {})

            " move the line
            let where = s:mv_line_dir is# 'up' ? '-1-' : '+'
            let where ..= cnt
            sil exe 'move '..where
        else
            " Vim doesn't provide the concept of extended mark; use a dummy text property instead
            call prop_type_add('tempmark', {'bufnr': bufnr('%')})
            call prop_add(line('.'), col('.'), {'type': 'tempmark'})

            " move the line
            if s:mv_line_dir is# 'up'
                " Why this convoluted `:move` just to move a line?  Why don't you simply move the line itself?{{{
                "
                " To preserve the text property.
                "
                " To move a line, internally, Vim  first copies it at some other
                " location, then removes the original.
                " The copy  does not inherit the  text property, so in  the end,
                " the latter  is lost.   But we  need it  to restore  the cursor
                " position.
                "
                " As a workaround, we don't move the line itself, but its direct
                " neighbor.
                "}}}
                exe '-'..cnt..',-m.|-'..cnt
            else
                " `sil!` suppresses `E16` when reaching the end of the buffer
                sil! exe '+,+1+'..(cnt-1)..'m-|+'
            endif
        endif

        " indent the line
        if &ft isnot# 'markdown' && &ft isnot# ''
            sil norm! ==
        endif
    catch
        return lg#catch_error()
    finally
        " restoration and cleaning
        if winbufnr(winid) == bufnr
            let [tabnr, winnr] = win_id2tabwin(winid)
            call settabwinvar(tabnr, winnr, '&fen', fen_save)
        endif
        " Why getting the info now?  Doing it later would allow us to get rid of 1 `has('nvim')`...{{{
        "
        " It would  not work as  expected when the cursor  is on the  very first
        " character of a line; see github issue #5663.
        "}}}
        if !has('nvim')
            " use the text property to restore the position
            let info = [prop_find({'type': 'tempmark'}, 'f'), prop_find({'type': 'tempmark'}, 'b')]
        endif
        " restore the view *after* re-enabling folding, because the latter may alter the view
        call winrestview(view)
        " restore cursor position
        if has('nvim')
            let pos = nvim_buf_get_extmark_by_id(0, ns_id, id) | let pos[0] += 1
            call call('cursor', pos)
            call nvim_buf_del_extmark(0, ns_id, id)
        else
            " remove the text property
            call prop_remove({'type': 'tempmark', 'all': v:true})
            call prop_type_delete('tempmark', {'bufnr': bufnr('%')})
            call filter(info, {_,v -> !empty(v)})
            if !empty(info)
                call cursor(info[0].lnum, info[0].col)
            endif
        endif
    endtry
endfu

fu brackets#mv_line_save_dir(dir) abort
    let s:mv_line_dir = a:dir
endfu

fu brackets#next_file_to_edit(cnt) abort "{{{1
    let here = expand('%:p')
    let cnt  = a:cnt

    " If we start Vim without any file argument, `here` is empty.
    " It doesn't cause any pb to move forward (`]f`), but it does if we try
    " to move backward (`[f`), because we end up stuck in a loop with:   here  =  .
    "
    " To fix this, we reset `here` by giving it the path to the working directory.
    if empty(here)
        let here = getcwd()..'/'
    endif

    " The main code of this function is a double nested loop.
    " We use both to move in the tree:
    "
    "    - the outer loop    to climb up    the tree
    "    - the inner loop    to go down     the tree
    "
    " We also use the outer loop to determine when to stop:
    " once `cnt` reaches 0.
    " Indeed, at the end of each iteration, we get a previous/next file.
    " It needs to be done exactly `cnt` times (by default 1).
    " So, at the end of each iteration, we update `cnt`, by [in|de]crementing it.
    while cnt != 0
        let entries = s:what_is_around(fnamemodify(here, ':h'))

        " We use `a:cnt` instead of `cnt` in our test, because `cnt` is going
        " to be [in|de]cremented during the execution of the outer loop.
        if a:cnt > 0
            " remove the entries whose names come BEFORE the one of the current
            " entry, and sort the resulting list
            call sort(filter(entries,{_,v -> v ># here}))
        else
            " remove the entries whose names come AFTER the one of the current
            " entry, sort the resulting list, and reverse the order
            " (so that the previous entry comes first instead of last)
            call reverse(sort(filter(entries, {_,v -> v <# here})))
        endif
        let next_entry = get(entries, 0, '')

        " If inside the current directory, there's no other entry before/after
        " the current one (depends in which direction we're looking)
        " then we update `here`, by replacing it with its parent directory.
        " We don't update `cnt` (because we haven't found a valid file), and get
        " right back to the beginning of the main loop.
        " If we end up in an empty directory, deep inside the tree, this will
        " allow us to climb up as far as needed.
        if empty(next_entry)
            let here = fnamemodify(here, ':h')

        else
            " If there IS another entry before/after the current one, store it
            " inside `here`, to correctly set up the next iteration of the main loop.
            let here = next_entry

            " We're only interested in a file, not a directory.
            " And if it's a directory, we don't know how far is the next file.
            " It could be right inside, or inside a sub-sub-directory …
            " So, we need to check whether what we found is a directory, and go on
            " until we find an entry which is a file. Thus a 2nd loop.
            "
            " Each time we find an entry which is a directory, we look at its
            " contents.
            " If at some point, we end up in an empty directory, we simply break
            " the inner loop, and get right back at the beginning of the outer
            " loop.
            " The latter will make us climb up as far as needed to find a new
            " file entry.
            "
            " OTOH, if there's something inside a directory entry, we update
            " `here`, by storing the first/last entry of its contents.
            let found_a_file = 1

            while isdirectory(here)
                let entries = s:what_is_around(here)
                if empty(entries)
                    let found_a_file = 0
                    break
                endif
                let here = entries[cnt > 0 ? 0 : -1]
            endwhile

            " Now that `here` has been updated, we also need to update the
            " counter. For example, if we've hit `3]f`, we need to decrement
            " `cnt` by one.
            " But, we only update it if we didn't ended up in an empty directory
            " during the inner loop.
            " Because in this case, the value of `here` is this empty directory.
            " And that's not a valid entry for us, we're only interested in
            " files.
            if found_a_file
                let cnt += cnt > 0 ? -1 : 1
            endif
        endif
    endwhile
    return here
endfu

fu s:what_is_around(dir) abort
    " If `dir` is the root of the tree, we need to get rid of the
    " slash, because we're going to add a slash when calling `glob('/*')`.
    let dir = substitute(a:dir, '/$', '', '')
    let entries  = glob(dir..'/.*', 0, 1)
    let entries += glob(dir..'/*', 0, 1)

    " The first call to `glob()` was meant to include the hidden entries,
    " but it produces 2 garbage entries which do not exist.
    " For example, if `a:dir` is `/tmp`, the 1st command will
    " produce, among other valid entries:
    "
    "         /tmp/.
    "         /tmp/..
    "
    " We need to get rid of them.
    call filter(entries, {_,v -> v !~# '/\.\.\?$'})

    return entries
endfu

fu brackets#put(_) abort "{{{1
    let cnt = v:count1

    if s:put_register =~# '[/:%#.]'
        " The type of the register we put needs to be linewise.
        " But, some registers are special: we can't change their type.
        " So, we'll temporarily duplicate their contents into `z` instead.
        let reg_save = [getreg('z'), getregtype('z')]
    else
        let reg_save = [getreg(s:put_register), getregtype(s:put_register)]
    endif

    " Warning: about folding interference{{{
    "
    " If one of  the lines you paste  is recognized as the beginning  of a fold,
    " and you  paste using  `<p` or  `>p`, the  folding mechanism  may interfere
    " unexpectedly, causing too many lines to be indented.
    "
    " You could prevent that by temporarily disabling 'fen'.
    " But doing so will sometimes make the view change.
    " So, you would also need to save/restore the view.
    " But doing so  will position the cursor right back  where you were, instead
    " of the first line of the pasted text.
    "
    " All in all, trying to fix this rare issue seems to cause too much trouble.
    " So, we don't.
    "}}}
    try
        if s:put_register =~# '[/:%#.]'
            let reg_to_use = 'z'
            call setreg('z', getreg(s:put_register), 'l')
        else
            let reg_to_use = s:put_register
        endif
        let reg_save = [reg_to_use] + reg_save

        " If  we've just  sourced some  line of  code in  a markdown  file, with
        " `+s{text-object}`, the register `o` contains its output.
        " We want it to be highlighted as a code output, so we append `~` at the
        " end of every non-empty line.
        if reg_to_use is# 'o'
            \ && &ft is# 'markdown'
            \ && synIDattr(synID(line('.'), col('.'), 1), 'name') =~# '^markdown.*CodeBlock$'
            let @o = join(map(split(@o, '\n'), {_,v -> v !~ '^$' ? v..'~' : v}), "\n")
        endif

        " force the type of the register to be linewise
        call setreg(reg_to_use, getreg(reg_to_use), 'l')

        " put the register (`s:put_where` can be `]p` or `[p`)
        exe 'norm! "'..reg_to_use..cnt..s:put_where..s:put_how_to_indent

        " make sure the cursor is on the first non-whitespace
        call search('\S', 'cW')
    catch
        return lg#catch_error()
    finally
        " restore the type of the register
        call call('setreg', reg_save)
    endtry
endfu

fu brackets#put_save_param(where, how_to_indent) abort "{{{1
    let s:put_where = a:where
    let s:put_how_to_indent = a:how_to_indent
    let s:put_register = v:register
endfu

fu brackets#put_line(_) abort "{{{1
    let cnt = v:count1
    let line = getline('.')
    let cml = '\V'..escape(matchstr(&l:cms, '\S*\ze\s*%s'), '\')..'\m'

    let is_first_line_in_diagram = line =~# '^\s*\%('..cml..'\)\=├[─┐┘ ├]*$'
    let is_in_diagram = line =~# '^\s*\%('..cml..'\)\=\s*[│┌┐└┘├┤]'
    if is_first_line_in_diagram
        if s:put_line_below && line =~# '┐' || !s:put_line_below && line =~# '┘'
            let line =  ''
        else
            let line =  substitute(line, '[^├]', ' ', 'g')
            let line =  substitute(line, '├', '│', 'g')
        endif
    elseif is_in_diagram
        let line = substitute(line, '\%([│┌┐└┘├┤].*\)\@<=[^│┌┐└┘├┤]', ' ', 'g')
        let l:Rep = {m ->
            \    m[0] is# '└' && s:put_line_below
            \ || m[0] is# '┌' && !s:put_line_below
            \ ? '' : '│'}
        let line = substitute(line, '[└┌]', l:Rep, 'g')
    else
        let line = ''
    endif
    let line = substitute(line, '\s*$', '', '')
    let lines = repeat([line], cnt)

    let lnum = line('.') + (s:put_line_below ? 0 : -1)
    " if we're in a closed fold, we don't want to simply add an empty line,
    " we want to create a visual separation between folds
    let [fold_begin, fold_end] = [foldclosed('.'), foldclosedend('.')]
    let is_in_closed_fold = fold_begin != -1

    if is_in_closed_fold && &ft is# 'markdown'
        " for  a  markdown  buffer,  where  we  use  a  foldexpr,  a  visual
        " separation means an empty fold
        let prefix = matchstr(getline(fold_begin), '^#\+')
        " fold marked by a line starting with `#`
        if prefix =~# '#'
            if prefix is# '#' | let prefix = '##' | endif
            let lines = repeat([prefix], cnt)
        " fold marked by a line starting with `===` or `---`
        elseif matchstr(getline(fold_begin+1), '^===\|^---') isnot# ''
            let lines = repeat(['---', '---'], cnt)
        endif
        let lnum = s:put_line_below ? fold_end : fold_begin - 1
    endif

    " could fail if the buffer is unmodifiable
    try
        call append(lnum, lines)
        " Why?{{{
        "
        " By default, we  set the foldmethod to `manual`, because  `expr` can be
        " much more expensive.
        " As a  consequence, when you  insert a  new fold, it's  not immediately
        " detected as such; not until you've temporarily switched to `expr`.
        " That's what `#compute()` does.
        "}}}
        if &ft is# 'markdown' && lines[0] =~# '^[#=-]'
            sil! call fold#lazy#compute()
        endif
    catch
        return lg#catch_error()
    endtry
endfu

fu brackets#put_line_save_param(below) abort "{{{1
    let s:put_line_below = a:below
endfu

fu brackets#put_lines_around(_) abort "{{{1
    " above
    call brackets#put_line_save_param(0)
    call brackets#put_line('')

    " below
    call brackets#put_line_save_param(1)
    call brackets#put_line('')
endfu

fu brackets#rule_motion(below, ...) abort "{{{1
    " after this function has been called from the command-line, we're in normal
    " mode; we need to get back to visual mode so that the search motion extends
    " the visual selection, instead of just moving the cursor
    if a:0 && a:1 is# 'vis' | exe 'norm! gv' | endif
    let cml = '\V'..escape(matchstr(&l:cms, '\S*\ze\s*%s'), '\')..'\m'
    let flags = (a:below ? '' : 'b')..'W'
    if &ft is# 'markdown'
        let pat = '^---$'
        let stopline = search('^#', flags..'n')
    else
        let pat = '^\s*'..cml..' ---$'
        let fmr = '\%('..join(split(&l:fmr, ','), '\|')..'\)\d*'
        let stopline = search('^\s*'..cml..'.*'..fmr..'$', flags..'n')
    endif
    let lnum = search(pat, flags..'n')
    if stopline == 0 || (a:below && lnum < stopline || !a:below && lnum > stopline)
        call search(pat, flags, stopline)
    endif
endfu

fu brackets#rule_put(below) abort "{{{1
    call append('.', ["\x01", '---', "\x01", "\x01"])
    if &ft isnot# 'markdown'
        +,+4CommentToggle
    endif
    sil keepj keepp +,+4s/\s*\%x01$//e
    if &ft isnot# 'markdown'
        sil exe 'norm! V3k=3jA '
    endif
    if !a:below
        -4m.
        exe 'norm! '..(&ft is# 'markdown' ? '' : '==')..'k'
    endif
    startinsert!
endfu

