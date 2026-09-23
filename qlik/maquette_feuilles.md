# Maquette de l'application Qlik Sense « Licences Dataiku »

Public visé : la direction et les admins Dataiku. Chaque utilisateur ne voit que les ADS
qui lui sont autorisées (section access sur `CODE_ADS`, alimentée par `ref_acces_qlik`).

## Modèle chargé

```
                    D_UTILISATEUR ──login──┐
                                           │
CALENDRIER ──mois── F_UTILISATEUR ──%cle_util_mois──┬── L_LICENCE ──CODE_ADS──┬── D_ADS
                                                    │        └──type_licence── D_TYPE_LICENCE
                                                    ├── F_ANOMALIE ──code_anomalie── D_ANOMALIE
                                                    └── F_GROUPE                     │
                                                               H_LICENCE ──CODE_ADS──┘
```

`H_LICENCE` est l'historique anonyme au-delà de 6 mois. Pour les graphiques d'historique,
utiliser ses propres champs `hist_mois` et `hist_type_licence` comme dimensions.

## Mesures de base (Master items)

Les données arrivent **une fois par mois** : une photo par mois, avec 6 photos nominatives
conservées. Par défaut, toutes les mesures portent sur le **dernier mois sélectionné**
(`$(vDerniere)`). On voit le dernier état sans avoir à choisir un mois, et on peut remonter
dans le temps en sélectionnant un autre mois.

| Mesure | Expression |
|---|---|
| Comptes actifs | `Count({<$(vDerniere), est_actif={1}>} DISTINCT login)` |
| Comptes actifs avec licence | `Count({<$(vDerniere), est_actif={1}, CODE_ADS-={'NON_ATTRIBUE'}>} DISTINCT login)` |
| Comptes dormants | `Count({<$(vDerniere), est_inactif={1}>} DISTINCT login)` |
| Taux de dormance | `Count({<$(vDerniere), est_inactif={1}>} DISTINCT login) / Count({<$(vDerniere), est_actif={1}>} DISTINCT login)` |
| Actifs jamais connectés | `Count({<$(vDerniere), est_actif={1}, est_jamais_connecte={1}>} DISTINCT login)` |
| Comptes en anomalie | `Count({<$(vDerniere), est_en_anomalie={1}>} DISTINCT login)` |
| Nombre d'anomalies | `Sum({<$(vDerniere)>} nb_anomalie)` |
| Taux de conformité | `1 - Count({<$(vDerniere), est_actif={1}, est_en_anomalie={1}>} DISTINCT login) / Count({<$(vDerniere), est_actif={1}>} DISTINCT login)` |
| Actifs (évolution) | `Count({<est_actif={1}>} DISTINCT login)` avec `annee_mois` en dimension |
| Dormants (évolution) | `Count({<est_inactif={1}>} DISTINCT login)` avec `annee_mois` en dimension |

Un utilisateur rattaché à plusieurs ADS (anomalie `MULTI_ADS`) est compté dans chacune d'elles.
Le total d'un graphique par ADS peut donc dépasser le nombre de comptes.

Volet de filtres présent sur toutes les feuilles : `ads_direction`, `ads_libelle`, `type_licence`,
`profil`, `annee_mois`.

---

## Feuille 1 : Vue d'ensemble (direction)

```
┌──────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
│ Comptes      │ Avec licence │ Dormants     │ Taux de      │ Comptes en   │
│ actifs       │              │ (> 90 j)     │ conformité   │ anomalie     │
│   KPI        │   KPI        │ KPI + taux   │ KPI (%)      │ KPI (rouge)  │
├──────────────┴──────────────┴──────┬───────┴──────────────┴──────────────┤
│ Licences par ADS                   │ Répartition par type de licence     │
│ Barres empilées horizontales       │ Barres (ou anneau si ≤ 4 types)     │
│ Dim : ads_libelle / type_licence   │ Dim : type_licence                  │
│ Mes : Comptes actifs avec licence  │ Mes : Comptes actifs avec licence   │
├────────────────────────────────────┴─────────────────────────────────────┤
│ Évolution des comptes actifs et dormants (6 photos mensuelles)           │
│ Courbe : Dim annee_mois ; Mes : Actifs (évolution), Dormants (évolution) │
└──────────────────────────────────────────────────────────────────────────┘
```

## Feuille 2 : Optimisation, licences dormantes

```
┌─────────────────────────────────────┬────────────────────────────────────┐
│ Ancienneté de la dernière connexion │ Dormants par ADS                   │
│ Barres : Dim tranche_inactivite     │ Barres triées décroissant          │
│ (0-30 / 31-90 / 91-180 / >180 /     │ Dim : ads_libelle                  │
│  jamais) ; Mes : Comptes actifs     │ Mes : Comptes dormants             │
│ Couleur : gradué vert → rouge       │ Libellé : taux de dormance         │
├─────────────────────────────────────┴────────────────────────────────────┤
│ Licences récupérables : tableau d'action                                 │
│ Colonnes : nom, login, email, ads_libelle, type_licence, profil,         │
│ date_derniere_connexion, jours_sans_connexion                            │
│ Filtre : {<$(vDerniere), est_inactif={1}>} ; tri : jours décroissant     │
└──────────────────────────────────────────────────────────────────────────┘
```

## Feuille 3 : Qualité et anomalies (admins)

```
┌──────────────────────────────┬───────────────────────────────────────────┐
│ Anomalies par type           │ Matrice profil × type de licence          │
│ Barres : Dim anomalie_libelle│ Tableau croisé coloré (heatmap)           │
│ Couleur : anomalie_gravite   │ Lignes : profil ; Colonnes : type_licence │
│ Mes : Nombre d'anomalies     │ Mes : Comptes actifs                      │
│                              │ → hors diagonale = incohérences           │
├──────────────────────────────┴───────────────────────────────────────────┤
│ Évolution des anomalies (le nettoyage avance-t-il ?)                     │
│ Barres empilées : Dim annee_mois / anomalie_gravite ;                    │
│ Mes : Sum(nb_anomalie)                                                   │
├──────────────────────────────────────────────────────────────────────────┤
│ Tableau détaillé : login, nom, anomalie_libelle, anomalie_gravite,       │
│ ads_libelle, type_licence, profil, nom_groupe                            │
│ Filtre : {<$(vDerniere)>} ; tri : gravité décroissante                   │
└──────────────────────────────────────────────────────────────────────────┘
```

## Feuille 4 : Tendances

```
┌─────────────────────────────────────┬────────────────────────────────────┐
│ Comptes actifs par type (6 mois)    │ Créations de comptes par mois      │
│ Courbes : Dim annee_mois,           │ Barres : Dim mois_creation         │
│ type_licence ; Mes : Actifs (évol.) │ Mes : Count(DISTINCT login)        │
├─────────────────────────────────────┴────────────────────────────────────┤
│ Consommation par ADS et par mois                                         │
│ Tableau croisé : Lignes ads_libelle ; Colonnes annee_mois ;              │
│ Mes : comptes actifs avec licence (une photo par mois) =                 │
│  Count({<est_actif={1}, CODE_ADS-={'NON_ATTRIBUE'}>} DISTINCT login)     │
├──────────────────────────────────────────────────────────────────────────┤
│ Historique long terme (anonyme, au-delà de 6 mois)                       │
│ Courbe : Dim hist_mois, hist_type_licence ;                              │
│ Mes : Sum(hist_nb_comptes_actifs), Sum(hist_nb_actifs_inactifs)          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Feuille 5 : Détail utilisateur

```
┌──────────────────────┬───────────────────────────────────────────────────┐
│ Recherche :          │ Fiche : nom, email, source_compte, date_creation, │
│ volet login / nom    │ profil, ADS, type_licence, dernière connexion     │
├──────────────────────┴───────────────────────────────────────────────────┤
│ Historique de l'utilisateur : tableau annee_mois, est_actif,             │
│ jours_sans_connexion, type_licence, CODE_ADS, anomalie_libelle           │
├──────────────────────────────────────────────────────────────────────────┤
│ Groupes Dataiku : tableau nom_groupe, est_groupe_licence                 │
│ Filtre : {<$(vDerniere)>}                                                │
└──────────────────────────────────────────────────────────────────────────┘
```

## Conventions visuelles

- Une couleur fixe par type de licence (Master item de dimension avec couleurs) et la
  même sur toutes les feuilles.
- Rouge réservé aux anomalies critiques et aux dormants, pour ne pas diluer l'alerte.
- Indicateurs en pourcentage : seuils conditionnels (par ex. dormance < 10 % en vert,
  10 à 25 % en orange, > 25 % en rouge), à ajuster avec la direction.
