# patches/

Coloque aqui arquivos `*.patch` (formato `git diff`) para serem aplicados sobre o nucleo baixado em `src/r4y-core`.
O `r4y.cmd` os aplica em ordem alfabetica depois de cada atualizacao. Um patch que nao aplica na versao atual e
ignorado com um aviso (nao interrompe o build).

Candidato natural: a correcao de estados de buffer do PR Marvisak/VIctory#479 (issue #445), em forma de patch
rebaseado sobre o `main` atual. Nao incluido aqui porque nao foi rebaseado nem testado.
