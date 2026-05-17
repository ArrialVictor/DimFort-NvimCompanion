-- Plugin entry point. Most users will call require("dimfort").setup({})
-- explicitly (lazy.nvim, packer, mini.deps, …), so this file is empty
-- on purpose — it only exists so `:packadd DimFort-NvimCompanion`
-- works for people who don't use a plugin manager.
--
-- If you'd like the plugin to auto-setup with defaults the moment it's
-- on the runtimepath, set ``vim.g.dimfort_autosetup = true`` *before*
-- the plugin loads, then we'll call setup({}) here.
if vim.g.dimfort_autosetup then
  require("dimfort").setup({})
end
