-- Insert a blank line below or above current line (do not move the cursor),
-- see https://stackoverflow.com/a/16136133/6064933
vim.keymap.set("n", "<space>o", "printf('m`%so<ESC>``', v:count1)", {
  expr = true,
  desc = "insert line below",
})

vim.keymap.set("n", "<space>O", "printf('m`%sO<ESC>``', v:count1)", {
  expr = true,
  desc = "insert line above",
})

-- Map <leader>ft to open a temporary markdown file
vim.keymap.set('n', '<leader>ft', function()
    local temp_file = vim.fn.expand("~/tmp/neotemp.md")
    local temp_dir = vim.fn.fnamemodify(temp_file, ":h")

    -- Create the directory if it doesn't exist (p flag handles parents)
    if vim.fn.isdirectory(temp_dir) == 0 then
        vim.fn.mkdir(temp_dir, "p")
    end

    -- Open the file in the current buffer
    vim.cmd("edit " .. temp_file)
end, { desc = "Open temporary markdown file" })
