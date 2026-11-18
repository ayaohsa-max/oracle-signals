# Archives ORACLE

Chaque version du robot et de l'indicateur est conservée ici, telle qu'elle a été publiée. La version en cours reste à la racine du dépôt (`ORACLE_Executor.mq5`, `SAV-WS.pine`).

Pour revenir à une version : ouvre le fichier, copie tout le code dans MetaEditor (ou dans l'éditeur Pine de TradingView), puis compile (F7).

## Robot ORACLE_Executor (MetaTrader 5)

| Version | Date | Changements | Fichier |
|---|---|---|---|
| v1.19 | 17/11/2026 | Réglages clés dans le signal de vie (contrôle à distance), 6 idées et risque total 2,1 % par défaut ; mesures SAV-WS pour l'optimisation : régime de marché du setup (ADX journalier, distance à la moyenne 200 jours en ATR, volatilité) et gain maximal atteint en R | [code](robot/ORACLE_Executor_v1.19.mq5) |
| v1.20 | 18/11/2026 | SAV-WS en réel : objectif plafonné à 3 R et filtre de volatilité journalière (ATR14/ATR100 entre 0,8 et 2,0), retenus par le backtest 8 ans H1 (19 actifs) : +0,19 R puis +0,10 R par trade sur la période de contrôle 2024-2026, 9 années gagnantes sur 9 ; or réintégré en réel à la demande du trader | [code](robot/ORACLE_Executor_v1.20.mq5) |
| v1.21 | 18/11/2026 | Journal plus précis : motif de chaque sortie (stop, objectif, manuel, coupure du robot, fermeture du vendredi, stop out) et journal des ordres annulés, affichés dans l'historique des trades d'ORACLE PRO | [code](robot/ORACLE_Executor_v1.21.mq5) |
| v1.18 | 17/11/2026 | Délai d'entrée SAV-WS (bougies entre le setup et l'exécution) noté dans le journal, pour choisir la meilleure durée de validité | [code](robot/ORACLE_Executor_v1.18.mq5) |
| v1.17 | 17/11/2026 | SAV-WS en réel : tendance de fond obligatoire (moyenne 200 jours), 3 confluences minimum, or exclu ; journal des setups marqué dans/contre la tendance | [code](robot/ORACLE_Executor_v1.17.mq5) |
| v1.16 | 17/11/2026 | SAV-WS en H1 seul, zone de l'unité supérieure obligatoire en réel, liste d'actifs tradés (tous par défaut) | [code](robot/ORACLE_Executor_v1.16.mq5) |
| v1.15 | 16/11/2026 | Journal de backtest par actif, indices groupés par bloc dans le plafond d'exposition, crypto le week-end (interrupteur du plan), testeur multi-unités | [code](robot/ORACLE_Executor_v1.15.mq5) |
| v1.14 | 15/11/2026 | Exposition par devise, 3 trades SAV-WS par jour, pause calendrier MT5, alerte de nouvelle version | [code](robot/ORACLE_Executor_v1.14.mq5) |
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
| v1.1 | 17/11/2026 | Aligné sur le robot v1.17 : zone de l'unité supérieure obligatoire, 3 confluences minimum, tendance de fond D1 (moyenne 200 jours) | [code](indicateur/SAV-WS_v1.1.pine) |
| v1.2 | 18/11/2026 | Aligné sur le robot v1.20 : objectif plafonné à 3 R, filtre de volatilité journalière 0,8-2,0 | [code](indicateur/SAV-WS_v1.2.pine) |
| v1.0 | 13/11/2026 | Filtres SAV-AFS + entrée WinStructure (Fibo 0,618 à 1, confluences, 2 confluences minimum) | [code](indicateur/SAV-WS_v1.0.pine) |

## Règle
À chaque nouvelle version, Claude ajoute le fichier ici et une ligne dans ce tableau.
