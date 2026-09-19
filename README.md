# CodexUsage

CodexUsage est une petite application macOS qui affiche les crédits Codex directement dans la barre des menus.

Elle permet de consulter rapidement :

- le crédit disponible sur la fenêtre de 5 heures ;
- le crédit disponible sur 7 jours ;
- l’heure de la dernière actualisation.

Les deux pourcentages restent visibles dans la barre des menus, sans avoir à garder la page d’utilisation de ChatGPT ouverte.

## Fonctionnement

L’application charge la page officielle d’utilisation Codex dans une vue web intégrée, puis lit les pourcentages qui y sont affichés. Les données sont actualisées automatiquement toutes les 60 secondes et peuvent aussi être rafraîchies manuellement.

La connexion s’effectue directement sur `chatgpt.com`. La vue web utilise le stockage de session WebKit de macOS ; l’application ne demande ni ne conserve elle-même le mot de passe du compte.

## Utilisation

1. Ouvrez le projet dans Xcode.
2. Compilez et lancez la cible `CodexUsage` sur macOS.
3. Connectez-vous à ChatGPT dans la fenêtre proposée si nécessaire.
4. Autorisez l’accès aux clés d’accès macOS si votre compte utilise une passkey.
5. Les crédits apparaissent ensuite dans la barre des menus.

Depuis la fenêtre de l’application, il est également possible d’actualiser les données, d’ouvrir la page d’utilisation dans le navigateur ou de quitter l’application.

## Prérequis

- macOS
- Xcode
- un compte ChatGPT disposant d’un accès à Codex
- une connexion Internet

## À savoir

CodexUsage est un projet indépendant et non officiel. Comme il lit les informations affichées par le site ChatGPT, une modification de cette page peut nécessiter une mise à jour de l’application.
