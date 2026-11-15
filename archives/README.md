# Archives ORACLE

Chaque version du robot et de l'indicateur est conservée ici, telle qu'elle a été publiée. La version en cours reste à la racine du dépôt (`ORACLE_Executor.mq5`, `SAV-WS.pine`).

Pour revenir à une version : ouvre le fichier, copie tout le code dans MetaEditor (ou dans l'éditeur Pine de TradingView), puis compile (F7).

## Robot ORACLE_Executor (MetaTrader 5)

| Version | Date | Changements | Fichier |
|---|---|---|---|
| v1.13 | 15/11/2026 | Journal des exécutions et positions dans le signal de vie, alerte consignes > 10 h, perte du jour 2,5 %, anti-doublon, mode testeur MT5 | [code](robot/ORACLE_Executor_v1.13.mq5) |
| v1.12 | 15/11/2026 | Alertes d'observation SAV-WS coupées par défaut, 5 idées max par défaut | [code](robot/ORACLE_Executor_v1.12.mq5) |
| v1.11 | 13/11/2026 | SAV-WS : mesure et option du passage au prix d'entrée ; consignes sans cache GitHub | [code](robot/ORACLE_Executor_v1.11.mq5) |
| v1.10 | 13/11/2026 | Gestion des anomalies : coupures, arrêt du PC, refus du courtier, rattrapage du vendredi | [code](robot/ORACLE_Executor_v1.10.mq5) |
| v1.09 | 13/11/2026 | Moteur SAV-WS (filtres SAV-AFS + entrée WinStructure) | [code](robot/ORACLE_Executor_v1.09.mq5) |
| v1.08 | 12/11/2026 | Signal de vie horaire, alerte consignes trop anciennes ou illisibles | [code](robot/ORACLE_Executor_v1.08.mq5) |
| v1.07 | 07/11/2026 | Perte max totale suiveuse (FTMO), bilan quotidien dans le journal | [code](robot/ORACLE_Executor_v1.07.mq5) |
| v1.06 | 06/11/2026 | Moteur SAV-AFS intégré (H1/H4, biais fondamental ORACLE, observation ou trading) | [code](robot/ORACLE_Executor_v1.06.mq5) |
| v1.05 | 05/11/2026 | Telegram, journal GitHub, filtre de spread, risque total, série de pertes, sortie ATR | [code](robot/ORACLE_Executor_v1.05.mq5) |
| v1.04 | 02/11/2026 | Fermeture du vendredi 21h45 (Paris) et pause week-end (règle FTMO) | [code](robot/ORACLE_Executor_v1.04.mq5) |
| v1.03 | 02/11/2026 | Ordres confirmés par le serveur, un seul robot par MT5, remplissage et expiration adaptés au courtier | [code](robot/ORACLE_Executor_v1.03.mq5) |
| v1.02 | 02/11/2026 | Adresse des consignes préremplie, première version publiée | [code](robot/ORACLE_Executor_v1.02.mq5) |

Les versions 1.00 et 1.01 n'ont pas été publiées dans le dépôt.

## Indicateur SAV-WS (TradingView)

| Version | Date | Changements | Fichier |
|---|---|---|---|
| v1.0 | 13/11/2026 | Filtres SAV-AFS + entrée WinStructure (Fibo 0,618 à 1, confluences, 2 confluences minimum) | [code](indicateur/SAV-WS_v1.0.pine) |

## Règle
À chaque nouvelle version, Claude ajoute le fichier ici et une ligne dans ce tableau.
