# Como as fontes se ligam

Leitura feita em 2026-11-24 dos READMEs de VIctory, victory-gta6, xcl e Leonida, da issue Marvisak/VIctory#445, do PR #479 e das listas recentes de PRs (VIctory) e de issues mais comentadas (xcl). Dos demais PRs/issues so os titulos foram lidos; nada abaixo vem de leitura do codigo-fonte.

## Mapa

| Projeto | Linguagem / API | Licenca | Papel |
|---|---|---|---|
| VIctory (Marvisak) | Rust, D3D12 do host, shaders RDNA2 → DXIL | GPL-3.0-or-later | Nucleo: loader, HLE, GPU, shaders |
| victory-gta6 (fxceless) | idem (fork) | GPL-3.0-or-later | Correcoes de render e velocidade em cima do VIctory |
| xcl (xcl-dev) | Rust, D3D12, RDNA2 → HLSL → DXIL | GPL-2.0-only | Camada mais ampla (varios jogos GDK); fonte de diagnosticos |
| Leonida (cmyk-ux) | Python + C++, Vulkan, RDNA2 → SPIR-V | GPL-3.0 | Recompilacao estatica e exportacao de assets; instalador de um clique |

## O que e comum

- **Mesmo alvo**: GTA VI para Xbox Series, pacote 1.0.2.1, com o codigo x86-64 do jogo rodando nativamente e o sistema do console reimplementado.
- **Mesmo problema de shader**: o codigo RDNA2 do console precisa virar shader de PC. VIctory e XCL vao para DXIL (D3D12); Leonida vai para SPIR-V (Vulkan).
- **Wave64 em GPU wave32**: aparece nos tres (XCL em `docs/wave64-on-wave32.md`, Leonida com `--wave64-emulate`, VIctory com os shaders que "precisam de 64 lanes"). E o principal risco em NVIDIA e Intel.
- **Politica de nao distribuir dados do jogo**: os quatro rejeitam arquivos do jogo no repositorio e dizem nao contornar protecao.

## O que o R4Y aproveitou de cada fonte

| Ideia | Origem | Onde esta no R4Y |
|---|---|---|
| Instalador unico em `.cmd` com payload PowerShell embutido, `--dry-run`, `--yes`, `--no-build`, log | Leonida | `r4y.cmd` |
| Procurar/perguntar a pasta do jogo e lembrar da escolha | Leonida (`Build.bat`) | `r4y.cmd`, passo 4 |
| Pre-teste de hardware antes de um build longo | Leonida (`pc_checker`) | `r4y.cmd`, passo 1 (AVX2, GPU, commit) |
| Checar memoria *commit* (erro 1455) | VIctory README | aviso no passo 1 |
| Modo seguro em software (`VICTORY_D3D12_WARP=1`) | VIctory README | `R4Y_D3D12_WARP` no `r4y-run.cmd` |
| Pasta do jogo nunca modificada; config fora do repositorio | VIctory / XCL | `config\r4y.toml` |
| DXC 1.8+ recomendado (1.7 gera DXIL maior e demora mais em NVIDIA) | xcl issue #156 | README, requisitos |
| Guia de Windows 10 e GPUs sem mesh shaders | VIctory PR #1665 (aberto) | referenciado; ainda nao incorporado |
| Comando `doctor` que explica problemas conhecidos em linguagem simples | VIctory PR #1609 (aberto) | ideia para o futuro |
| Canal com correcoes de render/velocidade | victory-gta6 | `--channel fork` |

## Issue #445 e PR #479 (suas publicacoes)

A #445 investiga a remocao do dispositivo D3D12 numa RTX 3070: o diagnostico mostrou um buffer em `UNORDERED_ACCESS` usado em `IASetVertexBuffers`, e separou isso de um shader compute que nao traduz (hash `6c86597c4a6c9c5a`). O PR #479 propunha rastrear o estado de cada copia de buffer por lista de comandos (transicoes entre vertex/index/constant/SRV/UAV/indirect e retorno ao estado comum no `close()`). Na data da leitura o PR constava como fechado e nao mesclado no upstream; o motivo nao esta nos dados lidos. Esta pasta `patches/` e o lugar para carregar essa correcao rebaseada no `main` atual.

## Pontos abertos nas fontes que valem acompanhar

- xcl #42: resultados de GPU (RTX 3080 wave32, iGPU RDNA2 sem mesh shaders); #1269: pedido de PRs de otimizacao de shaders.
- xcl #675 / #846 / #232 / #662: falhas recorrentes no mesmo ponto (`game_scarlett_master.exe+0x23cf683`) em varias RTX durante o carregamento da historia.
- VIctory #595 (submissoes assincronas numa linha do tempo de fences), #1660 (escrita atomica da biblioteca de pipelines; o fork corrigiu um problema ligado ao arquivo trocado enquanto mapeado), #1058 (testes de CI no Windows).

## Licencas: por que nao ha mistura de codigo

XCL e GPL-2.0-only; VIctory, victory-gta6 e Leonida sao GPL-3.0 (ou posterior). Codigo GPL-2.0-only nao pode ser combinado com GPL-3.0 num mesmo trabalho. Por isso o R4Y so usa o XCL como referencia (issues, documentacao publica), e o nucleo do VIctory e baixado no build em vez de copiado. Se quiser portar uma ideia do XCL, reescreva-a do zero, como o proprio victory-gta6 diz ter feito.

## Renomeacao

Foi feita onde e seguro: instalador, binario (`r4y.exe`), launcher, docs. Renomear crates e variaveis `VICTORY_*` no codigo exigiria um fork completo do VIctory com todo o historico; isso nao foi feito e, ao fazer, mantenha o aviso de copyright original (GPL exige).
