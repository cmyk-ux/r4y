# R4Y — Recompile4You

Camada de compatibilidade que roda **Grand Theft Auto VI (Xbox Series X|S)** nativamente no Windows, a partir de arquivos **do seu próprio jogo**, já legíveis em disco.

O R4Y reúne quatro linhas de trabalho abertas (detalhes em [docs/INTEGRACAO.md](docs/INTEGRACAO.md)):

| Origem | O que traz para o R4Y |
|---|---|
| [Marvisak/VIctory](https://github.com/Marvisak/VIctory) | Núcleo: loader, serviços de runtime, backend D3D12 e recompilador de shaders (RDNA2 → DXIL). **É o que o `r4y.cmd` compila.** |
| [fxceless/victory-gta6](https://github.com/fxceless/victory-gta6) | Fork do VIctory com correções de render e velocidade (canal `fork`). |
| [cmyk-ux/Leonida](https://github.com/cmyk-ux/Leonida) | O modelo do instalador de um clique e o pré-teste de hardware. |
| [xcl-dev/xcl](https://github.com/xcl-dev/xcl) | Referência de comportamento e diagnóstico. **Nenhum código copiado** (licença incompatível). |

> [!IMPORTANT]
> Este repositório **não contém o jogo, chaves, executáveis nem assets**, e não explica como obtê-los. Você precisa da sua própria cópia, com os arquivos já legíveis em disco. Nada aqui descriptografa ou contorna proteção. Grand Theft Auto e nomes relacionados são marcas de seus donos; o projeto não é afiliado à Rockstar Games nem à Take-Two.

## Status

**Ainda não jogável.** Depende do núcleo escolhido, segundo os READMEs das fontes em 2026-11-24:

- `upstream` (VIctory): boot, menus a 30 fps e carregamento do mundo funcionam; a renderização do mundo ainda falha ou é muito lenta.
- `fork` (victory-gta6): abertura e primeiro trecho jogável renderizam, em 2–4 fps; áreas em sombra ficam pretas (ray tracing ainda não roda).

O R4Y por si só não melhora esses números.

## Requisitos

- Windows 10/11 x64, CPU com AVX2.
- GPU Direct3D 12 com Shader Model 6.6 (e mesh shaders para o mundo).
- Vários GiB de *commit* livres na inicialização (Gerenciador de Tarefas → Desempenho → Memória → **Confirmado**). Se `crashes.log` citar o erro 1455, feche programas ou aumente o arquivo de paginação.
- O `r4y.cmd` instala o que faltar, com sua confirmação, via `winget`: Git, Rustup e Visual Studio 2022 Build Tools (C++ e Windows SDK).
- Recomendado: DXC 1.8 ou mais novo (o 1.7 gera DXIL bem maior e pode demorar muito para compilar pipelines em NVIDIA).

## Build fácil (um clique)

1. `git clone https://github.com/cmyk-ux/r4y` (use clone: o `.gitattributes` converte o `.cmd` para CRLF; o "Download ZIP" pode trazer quebras de linha erradas).
2. Dê dois cliques em **`r4y.cmd`**.

Passos, nesta ordem:

1. Verifica Windows, AVX2, GPU e memória de commit.
2. Lista o que falta e instala com consentimento.
3. Baixa/atualiza o núcleo em `src\r4y-core` e aplica os patches de `patches\`.
4. **Pergunta a pasta do jogo e o executável** que você quer rodar (digitando ou pelo seletor; lembra da última escolha).
5. Grava a configuração fora do repositório do núcleo (`config\r4y.toml`) e compila em release.
6. Copia para `bin\r4y.exe` e checa a configuração e o executável escolhido.
7. Cria `r4y-run.cmd` e pergunta se quer iniciar agora.

Rodar de novo atualiza o núcleo e recompila de forma incremental.

### Opções

```
r4y.cmd [--dry-run] [--no-build] [--no-run] [--yes] [--test] [--channel upstream|fork]

  --dry-run   só mostra o que falta; não altera nada
  --no-build  prepara tudo e grava a configuração, mas não compila
  --no-run    compila e checa, mas não pergunta se quer iniciar
  --yes       não pede confirmação para instalar pacotes
  --test      roda também cargo test --workspace (não usa dados do jogo)
  --channel   upstream (padrão) ou fork
```

Ao trocar de canal, `src\r4y-core` é redefinido para o novo repositório: não guarde alterações suas lá.

## Build manual

```powershell
git clone --depth 1 https://github.com/Marvisak/VIctory src\r4y-core
mkdir config
copy src\r4y-core\victory.example.toml config\r4y.toml    # edite game_dir (fora de src\)
$env:VICTORY_CONFIG = "$PWD\config\r4y.toml"
cd src\r4y-core
cargo build --release -p victory
target\release\victory.exe config
target\release\victory.exe run "D:\SeuJogo\executavel.exe" --execute
```

## Depois de instalado

Use `r4y-run.cmd`. Para outro jogo/executável, rode `r4y.cmd` de novo. A pasta do jogo nunca é modificada; saves e `crashes.log` ficam em `%LOCALAPPDATA%\victory\data`.

Variáveis que o `r4y-run.cmd` traduz: `R4Y_LOG`, `R4Y_D3D12_DEBUG`, `R4Y_D3D12_WARP` → `VICTORY_LOG`, `VICTORY_D3D12_DEBUG`, `VICTORY_D3D12_WARP`. Modo sem risco de resetar o driver: `set R4Y_D3D12_WARP=1` (renderiza no adaptador por software; lento).

> **Aviso.** Entrar no mundo em GPU real pode travar a GPU; o Windows então reinicia o driver de vídeo (os monitores ficam pretos por um instante).

## Estrutura

```
r4y.cmd             instalador/atualizador/compilador de um clique
patches/            patches aplicados sobre o núcleo (*.patch, em ordem)
docs/INTEGRACAO.md  como as fontes se ligam e o que foi aproveitado
NOTICE.md           créditos e licenças
```

`src\`, `bin\`, `build\`, `config\` e logs são gerados na sua máquina e ficam fora do git.

## Limitações desta versão

- O nome R4Y está no instalador, no binário (`r4y.exe`), nos launchers e na documentação. Identificadores internos do código do núcleo (crates `victory_*`, variáveis `VICTORY_*`) continuam originais, porque o código é baixado do upstream no build.
- O `r4y.cmd` foi escrito sem poder ser executado em Windows; teste e relate falhas em issues.
- O pipeline de assets do Leonida (Python/Vulkan, cerca de 400 GB) não está ligado ao instalador.

## Licença

GPL-3.0-or-later. Veja `LICENSE` e [NOTICE.md](NOTICE.md).
