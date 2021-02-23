if exists('g:loaded_compe_dict')
  finish
endif
let g:loaded_compe_dict = v:true

if exists('g:loaded_compe')
  lua require'compe'.register_source('dict', require'compe_dict')
endif

