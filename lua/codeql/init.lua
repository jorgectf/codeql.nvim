local util = require "codeql.util"
local queryserver = require "codeql.queryserver"
local config = require "codeql.config"
local ts_utils = require "nvim-treesitter.ts_utils"

local M = {}

function M.setup_codeql_buffer()
  local bufnr = vim.api.nvim_get_current_buf()

  -- set codeql buffers as scratch buffers
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

  -- set mappings
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd [[nmap <buffer>gd <Plug>(CodeQLGoToDefinition)]]
    vim.cmd [[nmap <buffer>gr <Plug>(CodeQLFindReferences)]]
  end)

  -- load definitions and references
  M.load_definitions(bufnr)
end

function M.load_definitions(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)

  -- check if file has already been processed
  local defs = require "codeql.defs"
  local fname = vim.split(bufname, "://")[2]
  if defs.processedFiles[fname] then
    return
  end

  -- query the buffer for defs and refs
  M.run_templated_query("localDefinitions", fname)
  M.run_templated_query("localReferences", fname)

  -- prevent further definition queries from being run on the same buffer
  defs.processedFiles[fname] = true
end

function M.set_database(dbpath)
  local conf = config.get_config()
  conf.ram_opts = util.resolve_ram(true)
  local database = vim.fn.fnamemodify(vim.trim(dbpath), ":p")
  if not vim.endswith(database, "/") then
    database = database .. "/"
  end
  if not util.is_dir(database) then
    util.err_message("Incorrect database: " .. database)
  else
    local metadata = util.database_info(database)
    metadata.path = database
    queryserver.register_database(metadata)
  end
  --TODO: print(util.database_upgrades(config.database.dbscheme))
end

local function is_predicate_node(node)
  return node:type() == "charpred" or node:type() == "memberPredicate" or node:type() == "classlessPredicate"
end

local function is_predicate_identifier_node(predicate_node, node)
  return (predicate_node:type() == "charpred" and node:type() == "className")
    or (predicate_node:type() == "classlessPredicate" and node:type() == "predicateName")
    or (predicate_node:type() == "memberPredicate" and node:type() == "predicateName")
end

function M.get_enclosing_predicate_position()
  local node = ts_utils.get_node_at_cursor()
  print(vim.inspect(node:type()))
  if not node then
    vim.notify("No treesitter CodeQL parser installed", 2)
  end
  local parent = node:parent()
  local root = ts_utils.get_root_for_node(node)
  while parent and parent ~= root and not is_predicate_node(node) do
    node = parent
    parent = node:parent()
  end
  if is_predicate_node(node) then
    for child in node:iter_children() do
      if is_predicate_identifier_node(node, child) then
        print(string.format("Evaluating '%s' predicate", child))
        local srow, scol, erow, ecol = child:range()
        local midname = math.floor((scol + ecol) / 2)
        return { srow + 1, midname, erow + 1, midname }
      end
    end
    vim.notify("No predicate identifier node found", 2)
    return
  else
    vim.notify("No predicate node found", 2)
  end
end

function M.get_current_position()
  local srow, scol, erow, ecol

  if vim.fn.getpos("'<")[2] == vim.fn.getcurpos()[2] and vim.fn.getpos("'<")[3] == vim.fn.getcurpos()[3] then
    srow = vim.fn.getpos("'<")[2]
    scol = vim.fn.getpos("'<")[3]
    erow = vim.fn.getpos("'>")[2]
    ecol = vim.fn.getpos("'>")[3]

    ecol = ecol == 2147483647 and 1 + vim.fn.len(vim.fn.getline(erow)) or 1 + ecol
  else
    srow = vim.fn.getcurpos()[2]
    scol = vim.fn.getcurpos()[3]
    erow = vim.fn.getcurpos()[2]
    ecol = vim.fn.getcurpos()[3]
  end

  return { srow, scol, erow, ecol }
end

function M.quick_evaluate_enclosing_predicate()
  local position = M.get_enclosing_predicate_position()
  if position then
    M.query(true, position)
  end
end

function M.quick_evaluate()
  M.query(true, M.get_current_position())
end

function M.run_query()
  M.query(false, M.get_current_position())
end

function M.query(quick_eval, position)
  local db = config.database
  if not db then
    util.err_message "Missing database. Use :SetDatabase command"
    return
  end

  local dbPath = config.database.path
  local queryPath = vim.fn.expand "%:p"

  local libPaths = util.resolve_library_path(queryPath)
  if not libPaths then
    util.err_message "Could not resolve library paths"
    return
  end

  local opts = {
    quick_eval = quick_eval,
    bufnr = vim.api.nvim_get_current_buf(),
    query = queryPath,
    dbPath = dbPath,
    startLine = position[1],
    startColumn = position[2],
    endLine = position[3],
    endColumn = position[4],
    metadata = util.query_info(queryPath),
    libraryPath = libPaths.libraryPath,
    dbschemePath = libPaths.dbscheme,
  }

  queryserver.run_query(opts)
end

local templated_queries = {
  c = "cpp/ql/src/%s.ql",
  cpp = "cpp/ql/src/%s.ql",
  java = "java/ql/src/%s.ql",
  cs = "csharp/ql/src/%s.ql",
  go = "ql/lib/%s.ql",
  javascript = "javascript/ql/src/%s.ql",
  python = "python/ql/src/%s.ql",
  ruby = "ql/src/ide-contextual-queries/%s.ql",
}

function M.run_print_ast()
  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.fn.bufname(bufnr)

  -- not a codeql:/ buffer
  if not vim.startswith(bufname, "codeql:/") then
    return
  end

  local fname = vim.split(bufname, ":")[2]
  M.run_templated_query("printAst", fname)
end

function M.run_templated_query(query_name, param)
  local bufnr = vim.api.nvim_get_current_buf()
  local dbPath = config.database.path
  local ft = vim.bo[bufnr]["ft"]
  if not templated_queries[ft] then
    --util.err_message(format('%s does not support %s file type', query_name, ft))
    return
  end
  local query = string.format(templated_queries[ft], query_name)
  local queryPath
  local conf = config.get_config()
  for _, path in ipairs(conf.search_path) do
    local candidate = string.format("%s/%s", path, query)
    if util.is_file(candidate) then
      queryPath = candidate
      break
    end
  end
  if not queryPath then
    vim.notify(string.format("Cannot find a valid %s query", query_name), 2)
    return
  end

  local templateValues = {
    selectedSourceFile = {
      values = {
        tuples = { { { stringValue = "/" .. param } } },
      },
    },
  }
  local libPaths = util.resolve_library_path(queryPath)
  local opts = {
    quick_eval = false,
    bufnr = bufnr,
    query = queryPath,
    dbPath = dbPath,
    metadata = util.query_info(queryPath),
    libraryPath = libPaths.libraryPath,
    dbschemePath = libPaths.dbscheme,
    templateValues = templateValues,
  }
  require("codeql.queryserver").run_query(opts)
end

local function open_from_archive(bufnr, zipfile, path)
  vim.api.nvim_set_current_buf(bufnr)
  local cmd = string.format("keepalt silent! read! unzip -p -- %s %s", zipfile, path)
  vim.cmd(cmd)
  vim.cmd "normal! ggdd"
  pcall(vim.cmd, "filetype detect")
  vim.api.nvim_buf_set_option(bufnr, "modified", false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.cmd "doau BufEnter"
end

function M.load_buffer()
  local db = config.database
  if not db then
    util.err_message "Missing database. Use :SetDatabase command"
    return
  else
    local bufnr = vim.api.nvim_get_current_buf()
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local path = string.match(bufname, "codeql://(.*)")
    open_from_archive(bufnr, db.sourceArchiveZip, path)
  end
end

function M.setup(opts)
  if vim.fn.executable "codeql" then
    config.setup(opts or {})

    -- highlight groups
    vim.cmd [[highlight default link CodeqlAstFocus CursorLine]]
    vim.cmd [[highlight default link CodeqlRange Error]]

    -- commands
    vim.cmd [[command! -nargs=1 -complete=file SetDatabase lua require'codeql'.set_database(<f-args>)]]
    vim.cmd [[command! UnsetDatabase lua require'codeql.queryserver'.unregister_database(<f-args>)]]
    vim.cmd [[command! RunQuery lua require'codeql'.run_query()]]
    vim.cmd [[command! QuickEvalPredicate lua require'codeql'.quick_evaluate_enclosing_predicate()]]
    vim.cmd [[command! -range QuickEval lua require'codeql'.quick_evaluate()]]
    vim.cmd [[command! StopServer lua require'codeql.queryserver'.stop_server()]]
    vim.cmd [[command! History lua require'codeql.history'.menu()]]
    vim.cmd [[command! PrintAST lua require'codeql'.run_print_ast()]]
    vim.cmd [[command! -nargs=1 -complete=file LoadSarif lua require'codeql.loader'.load_sarif_results(<f-args>)]]
    vim.cmd [[command! ArchiveTree lua require'codeql.explorer'.draw()]]

    -- autocommands
    vim.cmd [[augroup codeql]]
    vim.cmd [[au!]]
    vim.cmd [[au BufEnter * if &ft ==# 'codeqlpanel' | execute("lua require'codeql.panel'.apply_mappings()") | endif]]
    vim.cmd [[au BufEnter codeql://* lua require'codeql'.setup_codeql_buffer()]]
    vim.cmd [[au BufReadCmd codeql://* lua require'codeql'.load_buffer()]]
    vim.cmd [[augroup END]]

    -- mappings
    vim.cmd [[nnoremap <Plug>(CodeQLGoToDefinition) <cmd>lua require'codeql.defs'.find_at_cursor('definitions')<CR>]]
    vim.cmd [[nnoremap <Plug>(CodeQLFindReferences) <cmd>lua require'codeql.defs'.find_at_cursor('references')<CR>]]
    vim.cmd [[nnoremap <Plug>(CodeQLGrepSource) <cmd>lua require'codeql.grepper'.grep_source()<CR>]]
  end
end

return M
