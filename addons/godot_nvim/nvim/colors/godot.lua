-- The Godot editor's script editor colors. godot_nvim.set_theme supplies
-- them; without the editor running there's nothing to apply.
if _G.godot_nvim and _G.godot_nvim.theme then
  _G.godot_nvim.apply_theme()
else
  vim.notify("colorscheme godot: needs the Godot editor's colors", vim.log.levels.WARN)
end
