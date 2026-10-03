<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/icon-dark.png">
    <img src="docs/assets/icon.png" width="128" height="128" alt="Ícone do Garden: um broto saindo de uma moeda">
  </picture>
</p>

<h1 align="center">Garden</h1>

<p align="center">
  Finanças pessoais para quem vive no Brasil. Saiba <b>para quem</b> foi o seu dinheiro, <b>onde</b> você gastou e <b>quanto ainda sobra</b> até o dia do pagamento.
</p>

<p align="center">
  iPhone · iPad · Mac &nbsp;·&nbsp; SwiftUI &nbsp;·&nbsp; Open Finance pelo Meu Pluggy &nbsp;·&nbsp; Cloudflare Workers
</p>

---

## Por que o Garden

A maioria dos apps de finanças mostra "PAG*JOSE" ou "MP*LOJA" e para por aí. O Garden tenta responder as perguntas que importam:

- **Para quem eu paguei?** Reconhece mais de 130 marcas (Uber, 99, iFood, Mercado Livre, Atacadão…) e consulta o CNPJ no registro público da Receita. Assim, a padaria da esquina aparece como padaria, com nome e endereço, e não como "Compra no débito".
- **Quanto ainda sobra?** A **Sobra do mês** vai do dia do pagamento até o próximo. Você escolhe como ela é calculada: por um **teto** ("no máximo R$ 5.000 no mês"), pelo **salário**, ou pelos **limites de cada categoria**.
- **Para onde foi o dinheiro?** Um anel por categoria mostra o ciclo inteiro de relance, e um gráfico de ritmo compara o que você gastou com o que deveria ter gasto até aqui.
- **Isso é gasto mesmo?** Um Pix do BTG para o seu Nubank aparece como **"BTG → Nubank"**, não como despesa. Fatura do cartão, saque e aplicações também ficam fora dos gastos.
- **E na hora?** Uma automação do Atalhos registra cada compra do Apple Pay e cada notificação do banco no momento em que acontece, com o local. Quando o lançamento do banco chega pelo Open Finance, o Garden confirma a captura sem contar duas vezes.

## O que tem

| | |
|---|---|
| **Início** | Sobra do mês, ritmo de gastos, "pra conferir", para onde foi o dinheiro e os lançamentos recentes |
| **Extrato** | Tudo por dia, com logo da marca, forma de pagamento e categoria editável em 2 toques |
| **Categorias** | Anel de gastos estilo WalletPal e um limite opcional por categoria |
| **Patrimônio** | Contas, cartões e investimentos, com "disponível hoje" e "resgate a partir de" |
| **Buscar** | "Quanto gastei no iFood neste ciclo?" |
| **Salário** | Marque o pagador uma vez: o Garden reconhece os próximos e sugere o dia em que seu mês começa |
| **Captura automática** | App Intent para o Atalhos: compra no Apple Pay e notificações do Nubank e do BTG |
| **Widgets** | Sobra do mês (pequeno, médio e na tela bloqueada), Para onde foi o dinheiro (médio e grande) e o controle "Lançar" na Central de Controle |

## Como começar

1. **Abra no Xcode 27** o `Garden.xcodeproj` e rode no iPhone, iPad ou Mac (iOS/macOS 27).
2. **Conecte seus bancos** seguindo o guia [Conectando seus bancos com o Meu Pluggy](docs/PLUGGY.md). Leva uns 20 minutos, uma vez só.
3. **Configure a captura na hora** em *Ajustes ▸ Apple Pay e notificações do banco*.

Sem bancos conectados, o Garden também funciona só com lançamentos manuais e a captura do Apple Pay.

## Como está organizado

```
Garden/            app SwiftUI (iPhone, iPad, Mac)
GardenWidgets/     widgets e o controle "Lançar" (WidgetKit)
Shared/            o resumo que o app grava para os widgets (App Group)
  Ledger/          regras de dinheiro: categorização, marcas, CNPJ, notificações
  Sync/            sincronização com o Worker e o Pluggy
  Features/        telas
  Garden.icon/     ícone (Icon Composer)
worker/            Cloudflare Worker: proxy do Pluggy, sem guardar dados financeiros
docs/              design, fluxos, guia do Pluggy
```

- O **app** guarda tudo no aparelho, com SwiftData, valores em centavos inteiros e IDs determinísticos.
- O **Worker** guarda o segredo do Pluggy e não guarda transações. Tem 19 testes que rodam no workerd e um Pluggy simulado para desenvolver sem credenciais.

## Documentação

- [Conectando seus bancos com o Meu Pluggy](docs/PLUGGY.md): o passo a passo.
- [Design](docs/DESIGN.md): arquitetura, regras de conciliação, transferências, parcelamentos, privacidade.
- [Fluxos](docs/FLOWS.md): cada tarefa em no máximo 2 toques.
- [Revisão](docs/REVIEW.md): o que os agentes revisores encontraram e o que mudou.
- [Worker](worker/README.md): deploy, desenvolvimento local e testes.

## Privacidade

Seus dados financeiros ficam no seu aparelho. O Worker roda na **sua** conta da Cloudflare e só repassa os dados do Pluggy. Os logos das marcas são buscados direto no site de cada uma, sem passar por serviços de terceiros. O CPF nunca é salvo em texto.

> Projeto pessoal. O Meu Pluggy é gratuito apenas para uso pessoal (até 5 conexões).
