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

Les exécutions de mise à jour sont sérialisées. Un push ou une PR sur ces fichiers lance uniquement leur validation, sans accès au compte machine et sans mise à jour des consommateurs.

## Notification après publication

Le dernier job de `inrage/docker-wordpress` appelle ce workflow après la réussite de toutes les variantes publiées sur `main`. Les publications WordPress sont également sérialisées ; un échec de la matrice ne déclenche pas le scan.

Le mode de configuration suivant copie le jeton machine déjà utilisé par `inrage/images` dans le secret chiffré `IMAGES_DISPATCH_TOKEN` du dépôt producteur :

```sh
gh workflow run renovate-wordpress.yml --repo inrage/images -f mode=configure-notifier
```

Ce mode nécessite que le compte machine puisse gérer les secrets de `inrage/docker-wordpress`. Le jeton n'est pas affiché. Il doit être relancé après rotation du jeton source. Le compte utilisé et ses scopes sont vérifiés dans les logs ; aucun jeton personnel supplémentaire n'est introduit.

## Configuration et protections

`renovate-wordpress.json` contient la politique commune. `renovate-wordpress.dry-run.cjs` ajoute `dryRun: full` et le blocage des écritures API GitHub. Ces deux protections doivent rester ensemble : Renovate 44.262.1 ne protège pas tous ses nettoyages d'issues avec son seul mode simulation.

L'image officielle Renovate 44.262.1 est épinglée par digest. Les configurations sont validées sans réseau. Le nettoyage des anciennes branches, les migrations de configuration, les alertes de vulnérabilité et la maintenance des fichiers de verrouillage sont désactivés. Le dashboard utilise un titre distinct de celui de Mend.

Une fusion ultérieure peut déclencher les pipelines de production propres au projet. Aucun build ou déploiement de consommateur n'est lancé directement par ce workflow. Réactiver l'automerge nécessitera un véritable contrôle de construction de l'image avant fusion.

## Essai initial

Le 25 novembre 2026, la simulation initiale a parcouru 122 dépôts en 25 minutes 31 secondes, sans erreur : 33 configurés, 84 sans configuration, quatre vides et un fork ignoré. Elle a identifié 30 consommateurs et 41 changements de digest, sans changement de tag. Le regroupement et le préfixe dédiés ont ensuite été validés avec les 30 configurations observées.
