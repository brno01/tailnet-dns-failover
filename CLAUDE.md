# tailnet-dns-failover

<!-- Gerado por dev-project em 2026-11-11. Mantenha curto (< 200 linhas): só o que o Claude não descobre sozinho lendo o código. -->

## Visão geral
- Área: personal
- O que é: GitHub Actions (a cada 5 min) que entra na tailnet como nó efêmero (`tag:dns-failover`), testa o Pi-hole com `dig` e mantém o DNS da tailnet só no Pi-hole enquanto ele responde; troca para a Quad9 quando ele (ou o host) cai. Motivo: o Tailscale consulta todos os nameservers em paralelo, então um público "de reserva" na lista vaza consultas e anúncios.

## Stack
Bash + `curl` + `jq`, GitHub Actions. Testes com `bats` (via Homebrew). Sem gerenciador de pacotes.

## Comandos
| Ação | Comando |
|---|---|
| Testes | `bats tests/` |
| Lint | `shellcheck failover.sh tests/fake-curl` |
| Rodar contra a tailnet real sem mudar nada | `DRY_RUN=1 TS_OAUTH_CLIENT_ID=… TS_OAUTH_CLIENT_SECRET=… TS_DEVICE=… PRIMARY_DNS=… ./failover.sh` |

## Estrutura
- `failover.sh`: toda a lógica (token OAuth, estado do dispositivo, lista atual, troca).
- `.github/workflows/failover.yml`: agendamento a cada 5 min, `workflow_dispatch` com dry run e passo semanal que reabilita o workflow (regra dos 60 dias).
- `.github/workflows/test.yml`: shellcheck + bats em push/PR.
- `tests/`: `failover.bats` (fakes de `dig` e `tailscale` criados no `setup`) e `fake-curl` (fixtures por URL, grava os POSTs).

## Convenções
- Branch padrão: `master`. Trabalhe em branches de feature.
- O script só alterna entre `PRIMARY_DNS` e `FALLBACK_DNS`; lista diferente é mudança manual e não é tocada.

## Cuidados
- **Repositório público, logs públicos:** nunca imprimir nome do dispositivo, IPs da tailnet, nome da tailnet nem o token. Tudo que identifica a tailnet vai em *secrets* (`TS_DEVICE`, `PRIMARY_DNS`), que o GitHub mascara. Há teste para isso.
- O cliente OAuth do repo tem só `dns`, `devices:core:read` e `auth_keys` (restrito a `tag:dns-failover`, que na política da tailnet só alcança a porta 53 do Pi-hole). Nenhuma credencial mais ampla vai para o GitHub.
- Na dúvida (sem resposta do Pi-hole e host inalcançável pelo runner, ou runner fora da tailnet com host online), o script **não troca nada**: evita failover falso por problema do GitHub. Mantenha essa regra.
- Repositório público: detalhes da infraestrutura (nomes de host, caminhos, backups) ficam no vault do Obsidian, não aqui.
