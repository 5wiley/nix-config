require("obsidian").setup {
  workspaces = {
    {
      name = "Personal",
      path = "~/Documents/Obsidian/Personal/",
    }
  },
}

vim.keymap.set("n", "gf", ":ObsidianFollowLink<CR>", { noremap = true, silent = true })
