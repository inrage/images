# Mises à jour des images WordPress

Le workflow `Update WordPress consumers` découvre les dépôts accessibles de `inrage/*`, puis leurs références à `inrage/docker-wordpress`. Il n'existe aucune liste de sites à maintenir. Chaque dépôt doit déjà avoir sa configuration Renovate.

Les mises à jour sont regroupées dans une PR par dépôt, sur une branche `renovate-wordpress/`. Les restrictions de versions des projets sont conservées. La fusion automatique est forcée à `false` : les CI actuelles ne construisent pas systématiquement l'image avant fusion.

Le preset commun `inrage/inrage` exclut WordPress des traitements Mend via `wordpress-hosted-disabled`. Ce runner ignore seulement ce sous-preset d'exclusion ; les autres dépendances restent gérées par Mend. Le préfixe courant et l'ancien préfixe sont tous deux fixés à `renovate-wordpress/`, afin de ne pas reprendre les branches de l'autre bot.

## Lancer un passage

Simulation sans écriture :

```sh
gh workflow run renovate-wordpress.yml --repo inrage/images -f mode=simulate
```

Création ou actualisation des PR :

```sh
gh workflow run renovate-wordpress.yml --repo inrage/images -f mode=update
```

Le champ facultatif `repository_filter` permet de limiter un passage à un dépôt de l'organisation, par exemple `-f repository_filter=inrage/nom-du-depot`. Sa valeur par défaut reste `inrage/*`.

Les exécutions de mise à jour sont sérialisées. Le mode `update` exige la branche `main`. Un push ou une PR sur ces fichiers lance uniquement leur validation, sans accès à la clé de l'application et sans mise à jour des consommateurs.

## GitHub App

L'application dédiée doit être installée sur l'organisation `inrage` avec accès à tous ses dépôts, y compris les futurs dépôts. Le workflow demande un jeton pour cette installation sans inventaire de sites. L'identité du bot et son auteur Git sont détectés par Renovate à partir de ce jeton.

L'ancien auteur `361048373+inrage-renovate[bot]@users.noreply.github.com` reste reconnu pour les branches créées avant un renommage de l'application. Cette exception ne couvre aucun auteur humain et ne désactive pas le contrôle d'auteur des PR.

La variable d'organisation `INRBOT_APP_CLIENT_ID` et le secret `INRBOT_APP_PRIVATE_KEY` doivent être rendus accessibles uniquement à `images` et `docker-wordpress`. L'application sert aussi aux mises à jour des images de base. Aucun jeton personnel ni celui du compte utilisateur `InrBot` n'est utilisé par ce flux.

Le workflow `Update` reçoit un jeton `Contents: write` limité au dépôt d'image ciblé par chaque job : PHP, WordPress, PrestaShop ou FrankenPHP. Son auteur Git est dérivé de l'identité actuelle de l'application. Le jeton n'est pas enregistré dans les URL Git. Les publications GHCR conservent leur `GITHUB_TOKEN` natif ; les identifiants Docker Hub restent distincts.

Chaque job génère un jeton temporaire, valable au maximum une heure et révoqué à sa fin. Le mode `simulate` ne reçoit que des droits de lecture. Le mode `update` demande l'écriture sur Contents, Issues, Pull requests, Commit statuses et Workflows, ainsi que la lecture sur Administration, Checks et Members. Metadata reste implicitement en lecture. Les vérifications de mode, de branche et de filtre précèdent la création du jeton.

## Notification après publication

Après installation du relais, le dernier job de `inrage/docker-wordpress` appelle ce workflow après la réussite de toutes les variantes publiées sur `main`. Les publications WordPress sont également sérialisées ; un échec de la matrice ne déclenche pas le scan.

Le job producteur génère son propre jeton d'application, limité au dépôt `images` et à la permission Actions en écriture. Il peut ainsi déclencher le workflow consommateur sans recevoir ses droits d'écriture sur les sites. Une rotation de la clé privée s'effectue dans le secret d'organisation partagé.

## Configuration et protections

`renovate-wordpress.json` contient la politique commune. `renovate-wordpress.dry-run.cjs` ajoute `dryRun: full` et s'utilise avec le jeton GitHub App en lecture seule généré par le workflow. GitHub interdit ainsi les écritures que le seul mode simulation de Renovate 44.262.1 ne bloque pas, notamment certains nettoyages d'issues. Ce fichier ne doit pas être exécuté avec un jeton personnel disposant de droits d'écriture.

L'image officielle Renovate 44.262.1 est épinglée par digest. Les configurations sont validées sans réseau. Le nettoyage des anciennes branches, les migrations de configuration, les alertes de vulnérabilité et la maintenance des fichiers de verrouillage sont désactivés. Le dashboard utilise un titre distinct de celui de Mend.

Une fusion ultérieure peut déclencher les pipelines de production propres au projet. Aucun build ou déploiement de consommateur n'est lancé directement par ce workflow. Réactiver l'automerge nécessitera un véritable contrôle de construction de l'image avant fusion.

## Essai initial

Le 25 novembre 2026, la simulation initiale a parcouru 122 dépôts en 25 minutes 31 secondes, sans erreur : 33 configurés, 84 sans configuration, quatre vides et un fork ignoré. Elle a identifié 30 consommateurs et 41 changements de digest, sans changement de tag. Le regroupement et le préfixe dédiés ont ensuite été validés avec les 30 configurations observées.
