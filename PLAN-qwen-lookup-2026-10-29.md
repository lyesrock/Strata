# PLAN-2026-10-29-qwen-lookup - SOURCE DE VERITE

Projet : porter/améliorer le context-lookup drafting (PR amont #4619, moteur dsv41)
vers le moteur Qwen "strata". Ce fichier est la source de vérité : TOUTE decision
passe par une entree de Decision Log ici AVANT d'etre executee.

PROJET AMONT D'OU VIENT L'IDEE : HyperQwen (github.com/syv-ai/HyperQwen, Apache-2.0,
~2.4k stars) - patches/dflash2-lookup-drafting.patch + docs/optimizations.md,
section "Drafting from the context" : lookup dans l'historique de la requete,
point-mass lossless, bloc 15 declenche pendant la copie (DFLASH_TOKENS=15),
accord 2 tokens avec le drafter. Leur mesure : 7.83 -> 14.97 tok/pas, 260 -> 381 t/s.
Notre implementation dsv41 (PR #4619) est un portage independant ; le credit doit
rester dans le code, les commits, la PR et toute publication.

## Etat de départ (2026-10-29, acquis vérifiés file:line)

- Moteur cible = src/program/generate.cpp (binaire "strata", target CMakeLists:843).
  Le moteur Qwen a ALJA un stack speculative complet :
  * SuffixDrafter = prompt/context lookup (trigramme) par DEFAUT (--suffix-draft 3,
    suffix_drafter.hpp:19, generate.cpp:15700/16724).
  * MTP drafter GPU (mtp.cpp:1602), --lookup-chain (generate.cpp:16452),
    seam extensible extra_draft_sources() (draft_source.hpp:21-60,
    "can only change speed, never output"), DraftPolicy appris (draft_policy.hpp).
  * Acceptation probabiliste spec_prob avec regle point-mass DEJA presente
    (spec_prob.hpp, DETAILS.md:552-558) = la perte de notre trick dsv41 existe ici.
  * Fenetre de verify plafonnee : kVerifyMaxT = 8 (verify_kernels.hpp:21),
    graphes captures exec_[2][9] (verify.hpp:605). --suffix-draft monte spec de +2
    max 8 (generate.cpp:3747-3751). Config prod iq3_s : --spec 4 --suffix-draft 3 = spec 6.
  * Rollback : K/V append-only, jamais rewind ; commit = replay du prefixe accepte
    + snapshots GDN/indexer/PLE (verify.cpp:2761-2893). Pas de ring_bak a porter.
- Nos mesures dsv41 (5090) : copie +72 % (39.8 -> 68-70 t/s, 14.07 tok/manche) ;
  HyperQwen : 7.83 -> 14.97 tok/pas avec bloc 15. Qwen prod : 2.4-3.2 tok/pas (MTP),
  lookup jusqu'a 5-6. La difference qui compte = LA LONGUEUR DU BLOC, pas l'astuce lookup.

## Double analyse du 2026-10-29

- Ma carte du moteur (explore, file:line vérifiés) : ci-dessus.
- DeepSeek (opencode run -m SysAi2.Strata/Deepseek-v4.1-Flash, brut dans
  /tmp/opencode/qwen-lookup/analysis-deepseek-2.log) : "un port complet n'en vaut
  pas la peine ; le vrai levier = fenetre plus longue pour les manches de copie
  (idee DFLASH_TOKENS=15 de HyperQwen) via le seam draft_source + DraftPolicy".
  Auto-score 6/10 ; ses reservations (exec_[2][9], batch-mtp, cout P40) sont justes.
  CORRECTION apportee a son protocole : --suffix-draft ne monte PAS a 8 ; c'est --spec 6
  (+2 suffix) qui atteint le plafond 8. Ses claims non verifies sont marres ci-dessous.

## Decision Log

- 2026-10-31 (reprise 2) - MESURE ETAPE 5 (defaut byte-identical, cross-binaire patched vs STOCK) : 2 boots du
  binaire stock engine/strata.pre-patch (moteur 0.1.53 main 46c152a1, probe_stock.sh, copie seed402 sans instrument)
  + 2 relances = s1..s4. RESULTAT : le STOCK lui-meme a 2 streams sur 4 boots : {s1==s2 propre 6000} et {s3==s4
  flip 5834, byte 7447} ; ET ces streams sont BYTE-IDENTIQUES aux streams du binaire parche knob-off : b1==s1==s2
  (propre) et b2==b3==s3==s4 (flip, meme byte 7447, memes queues). DONC : (1) la non-reproductibilite temp-0 est
  une propriete du moteur STOCK (pre-patch), pas du patch ; (2) le chemin par defaut ne montre AUCUNE difference de
  stream cross-binaire sur 6 boots - byte-identity du defaut etablie aussi loin que mesurable (la byte-identity
  absolue est EMPIRIQUEMENT INDECIDABLE sur ce moteur : le stock ne la garantit pas lui-meme) + tests de parite
  unitaires + inspection (tout changement default = sizing seul ou gated env). BLD HIP/SYCL/METAL : NON EXECUTES -
  aucune toolchain (ni hipcc ni icx/icpx ni ROCm ni Intel) sur sysai2 ; note : SYCL compile sa PROPRE copie de
  verify.cpp (sycl/src/core/verify.cpp, non touchez par le patch) ; HIP compile le src/core/verify.cpp partage (le
  nouveau code est hors garde mais les symboles kVerifyLongT/preload_verify_long_kernels sont definis dans le meme
  .cu compile par hipcc - risque faible, NON VERIFIE = statique). RESTE ETAPE 5 : quality suite, credit HyperQwen
  dans le code/commits/PR (le credit est deja dans les commentaires generent: spec_long_on 2766-2769).

- 2026-10-31 (reprise 2) - NETTOYAGE ETAPE 4 + SURVIVANTS (EXECUTE) : (1) RETIRES du diff : bloc STRATA_DBG_DOT
  (cudaGraphDebugDotPrint) dans verify.cpp ; instrumentation BEFORE/AFTER cs_/n_vocab de stage_inputs (le dbg
  pos0/T par fenetre reste, env-gated, style maison type STRATA_VERIFY_NODES) ; backtrace+fprintf dans
  native_mmvq.cu validate_shape + les 3 includes ajoutes -> native_mmvq.cu revient EXACTEMENT a main (git diff
  vide sur le fichier). (2) NON TOUCHES car PREEXISTANTS dans main (verifie par git diff/grep : STRATA_DBG_NAN,
  g_dbg/STRATA_VERIFY_DEBUG ne sont PAS dans notre diff) - hors scope PR, une modification non liee = autre PR.
  (3) SURVIVANT generate.cpp:18131-18139 REJETE PAR VERIFICATION : dans le chemin generate, win_cap=o.spec (18254)
  plafonne T <= o.spec partout (T=min(T,room), room=min(win_cap,...)), policy ne propose que pk.t<=min(lookup_k,
  max_t_-1)+1 <= o.spec car propose(o.spec-1) ; buffers window/outv/fdiff/sbuf/accepted_hist dimensionnes o.spec =
  suffisants ; le ver init a max 12 n'est qu'un plafond. Pas de correctif. (4) SURVIVANT kv_stream CONFIRME STATIQUE
  et CORRIGE : verify.cpp:2072 passe n_q=T a qsa_kv_resolve quand kv_mode==1 (streaming, prod max-context 262144 +
  --kv-resident) ; contrat kv_stream.hpp:85-88 (n_slots >= n_q*(cap/page+2)) ; kv_stream.cu:146 "overflow: never
  happens with a legal n_slots" + ctl[3]=1 que RIEN ne lit dans verify -> risqu page_table=-1 en decode avec
  T=9..12. FIX : gardeg_spec_long_capped_by_kv (generate.cpp, avant les deux ver.init serve/generate) : si le knob
  est ON et kv_mode==1, spec_long_cap() rend kVerifyMaxT et le boot affiche "the long window is capped at 8 rows
  for this start". TESTE : boot prod (262144, kv-resident 32768, parallel=2, batch-mtp) + STRATA_SPEC_LONG=1 + DBG :
  warning present, T max observe 8 (249 stages), copie courte 800 tok OK, GPU vide apres (le timeout de la commande
  de kill etait le rm final, pas un process restant). ctest -j2 apres nettoyage+garde = exactement les 6 echecs
  baseline. RESTE ETAPE 5 : builds HIP/SYCL des fichiers touches, defaut byte-identical vs release (KL/quality),
  wrappers mac, credit HyperQwen partout.

- 2026-10-31 (reprise 2) - MESURE ABBA VITESSE (etape 3, EXECUTEE, ordre B BL BL B = a1 a2 a3 a4, seed 401,
  parallel=1 des deux bras, config qw1-BL.json (max-context 16384, reserve 1500, spec6+suffix3), bench_qw1.py,
  chiffres = lignes "done: (N tok/s)" du moteur dans server.out, warmup jete ; medians de paires uniquement) :
    copy greedy : B (404.0, 397.6) -> 400.8 | BL (238.0, 355.8) -> 296.9 = -25.9 %
    copy t=1    : B (356.5, 375.4) -> 366.0 | BL (253.8, 292.5) -> 273.2 = -25.4 %
    prose greedy: B (185.0, 174.2) -> 179.6 | BL (174.8, 155.3) -> 165.1 = -8.1 %
    prose t=1   : B (203.7, 206.0) -> 204.9 | BL (207.5, 192.6) -> 200.1 = -2.4 %
  QUALITE (cote, pas une validation) : a1/a4 B = copies completes 3520 ; a2 BL = flip en copie (2694/2718, tails
  garbage) ; a3 BL = completes - en clean seul, copy greedy a3 355.8 vs 400.8 = -11.2 %. NOTE : a2/a3 melangent
  flip et vitesse (le flip change le contenu decode) ; le pair-median declare inclut a2 contamine - la valeur clean
  est donnee separement. Les fenetres >=9 ne sont pas comptees par l'histogramme spec depth (buckets = profondeur
  ACCEPTEE <=5, pas taille de fenetre) ; le nombre de suffix-windows change (a1 388 vs a2 152) ce qui suggere des
  fenetres longues declenchees dans a2. VERDICT honnete pour la PR : a parallel=1 la fenetre longue cap12 est
  NEGATIVE en vitesse sur ce banc (-26 % copie avec flip, -11 % clean, -2..-8 % prose) et le moteur n'est pas
  reproductible a temp 0 (M1/M2) - la revendication de gain HyperQwen n'est PAS reproduite ici (leur base = fenetre
  8, la notre etait deja a 6->8 gagne a la gate 1 en parallel=2). DECISION OPERATEUR ATTENDUE : publier comme
  experimental opt-in avec ces chiffres, ou ne pas publier la partie fenetre longue. Fichiers : logs/a[1-4].
  {server.out,eng.log,bench.txt}.

- 2026-10-31 (reprise 2) - MESURE M1 (taux no-tap, probe_notap.sh, copie seed402, AUCUN instrument) : B x3 (knob
  off) = {b1 6000, b2 5637, b3 5637} avec b2==b3 OCTET POUR OCTET et b1 divergent a partir du byte 7447 -> LE BRAS
  B par defaut a FLIPPE 1 fois sur 3 boots. BL cap12 x3 = {l1 5660, l2 5198, l3 5900} = 3 streams distincts
  (l1/l2 et l2/l3 divergent byte 3438 ; l1/l3 byte 5726). TAPS PASSIFS CONFIRMES : t9==b1 et t11==b2 OCTET POUR
  OCTET (le tap ne change pas le flux). Le bruit a des MODES recurrents (mêmes streams reviennent). MESURE M2
  (--expert-cache-cpu-order, generate.cpp:3302/7656, BL cap12 x2) : l4 4689 (garbage) vs l5 6000 - NON DETERMINISTE
  aussi (l4!=l5) -> la mitigation n'est PAS effective a n=2 ; note : l5==b1 byte-identical (mode propre revenu une
  fois, n=1, non concluant). CONSEQUENCE PORTEE PR : la claim "copie byte-identique B vs BL" est INAPPLICABLE sur ce
  moteur a temp 0 (le defaut lui-meme flippe) ; le rapport doit decrire : mechanisme = expert-cache GPU/CPU arrondis
  + eviction et DraftPolicy wall-clock-dependants (amont 0.2.9 Known problems, famille DeepSeek, CONFIRME Qwen par
  mesure), BL cap12 augmente le taux de flip (3/3 streams distincts vs 2/3 en B), perte de "losslessness byte"
  = consequence du moteur, pas du verify speculatif (les tests de parite unitaires restent la garantie correcte) ;
  --expert-cache-cpu-order signale comme non-mitigant. PROCHAINE : ABBA vitesse (plan etape 3, 4 boots B BL BL B
  seed 401 parallel=1, run_arm.sh B1/BL1 + bench_qw1.py), medians de paires seulement.

- 2026-10-31 (reprise 2) - MESURE TAP #5 + CONCLUSION MAJEURE (mecanisme ETABLI PAR MESURE) : t11 = bras B (knob
  OFF, chemin par defaut, taps+DBG, copie seed402) = 5637 tok vs t9 (MEME config, MEME seed) = 6000 : LE BRAS B
  LUI-MEME N'EST PAS DETERMINISTE cross-boot (le temoin B1a==B1b du 31/10 sans taps etait un echantillon chanceux).
  tapmatch t11 vs t9 : 289 premiers records acceptes identiques ; PREMIERE divergence = pos 2960 (record 289),
  fenetre (2960,T=6) SHAPE IDENTIQUE et tokens identiques dans les deux boots ; premier tap different = layer 43 :
  109/2560 floats, max rel 9.1e-06 (layer 44: 2.7e-05, 45: 3.7e-05 - amplification progressive) ; shapes ne
  divergent qu'apres (2986: T6 vs T8) - consequence, pas cause. A COTE, t10 (knob ON cap 8) vs t9 : divergence a
  pos 2815 layer 5 = 177/2560 floats max rel 4.6e-05 avec SHAPE différente (2815: T5 vs T4) ; t11/t9 meme shape ->
  divergence quand meme. MECANISME retenu (mesuree, coherent avec release amont 0.2.9 Known problems "DeepSeek non
  reproductible a temperature 0 cause expert cache CPU<->GPU (arrondis differents)") : l'expert-cache VRAM est OBLIGATOIRE
  pour verify (verify.cpp:832-838, impossible a desactiver sans changer le code), le melange hits (GPU) / misses (CPU)
  a des arrondis legerement differents (native_expert_parity.cpp:8-13 "a few 1e-3 relative" vs reference ; R4.2h
  generate.cpp:7716-7718 documente un desaccord 4.761e-04 corrige pour les scales seules), l'eviction LRU du cache et
  le DraftPolicy qui apprend sur round_ms (draft_policy.hpp:13-15 "measured round times") dependent du wall-clock ->
  perturbations ~1e-5..1e-3 -> en contexte profond (>2051 cellules) la SELECTION QSA (top-k) bascule pres des
  frontieres -> grands changements d'activations (max rel 1..100 observes aux layers 6/11/15) -> flip du 1er token
  (BL 2819 ; B 2960->7447 bytes) -> cascade. Le "bug BL" N'EST PAS un bug de losslessness de notre patch : c'est la
  non-reproductibilite du moteur (classe documentee en amont) AMPLIFIEE par les fenetres longues (plus de churn
  d'experts, plus de variance de shape). ACQUISITIONS REINTERPRETEES : cap 9/10/12 "tous divergent" vs cap8 jamais
  teste au knob (t10 propre x1 boot seulement - taux a mesurer) ; B "byte-identique" = chance ; prose B==BL =
  echantillon. PROCHAINES MESURES : (M1) taux no-tap : 3 boots B + 3 boots BL cap12 copie seed402, nb de paires
  divergentes et positions ; (M2) sonde --expert-cache-cpu-order (generate.cpp:3302, hit_cpu_order 7656) x2 boots BL :
  si elle reduit/supprime les flips -> piste de mitigation a proposer ; sinon documenter ; (M3) ABBA vitesse relance.
  Pour la PR : ne JAMAIS revendiquer la byte-identity copie (le moteur amont ne la garantit pas a temp 0) ;
  losslessness = verify n'accepte que ce qui matche (tests de parite unitaires) + comparaison probabiliste.

- 2026-10-31 (reprise 2) - MESURE TAP #4 (tapmatch.py : records ACCEPTES apparies (pos,tok) entre boots, t7=BL vs
  t9=B, seuil 2840) : les 81 premiers records acceptés apparies sont BYTE-IDENTIQUES ; PREMIERE DIVERGENCE
  NUMERIQUE = pos 2815 tok 52604 layer 5 (GDN) ; puis pos 2816 layer 0 (cascade par etat committe), 2817/2818
  layer 6 ; FLIP du token accepte a pos 2819 (BL 22916 vs B 1596). CONTEXTES MESURES : fenetre contenant pos 2815 =
  (2815,T=5) cote BL vs (2815,T=4) cote B - TOUS DEUX <=8 ; sequences de fenetres identiques jusqu'a 2812 puis
  shapes differentes des 2815 ; premier T>=9 = 2977 (bien apres). CONSEQUENCE MAJEURE : la divergence BL vs B ne
  REQUIERT PAS de fenetre >=9 pour DEMARRER - elle vient d'une difference numerique a T<=8 introduite par le knob
  (max_t_=12 au boot : sizing/planning/arena, propose(SCAP-1=11 vs 7, DraftPolicy kShape 13 vs 9, gated off via
  2800, precapture 10119/17834) - ou par la shape 5-vs-4 elle-meme. ACQUISITION ANTERIEURE A REINTERPRETER : le
  "cap 9 suffit" du bisect = toutes les caps testees 9/10/12 ont max_t_>=9 - cap 8 AU KNOB ON n'a JAMAIS ete teste.
  DECISION (sonde decisive t10) : STRATA_SPEC_LONG=1 + STRATA_SPEC_LONG_MAX=8 -> spec_long_on TRUE, max_t_ =
  max(batch_max_t,8)=8 = comme B ; propose(7) = comme B ; long_gate jamais declenche ; reste PRECAPTURE (capture_all
  par defaut) et gated-off : si t10 == B byte-identique (taps accepts jusqu'a ~3200) -> mecanisme = max_t_=12 au boot
  qui change le numerique des chemin <=8 (planning/sizing) - le "bug rows>=8" est en fait un effet max_t_ ; si t10
  diverge aussi -> effet knob residuel hors max_t_ (precapture/policy), bisect STRATA_PRECAPTURE=0 ensuite.

- 2026-10-31 (reprise 2) - MESURE TAP #3 + FLUX (t7/t8 = BL 2 boots avec STRATA_DBG_LAUNCH etendu (pos0,T par
  stage_inputs, build + cp fait, engine==build) ; t9 = bras B reference knob OFF, meme config, taps 0..46 + DBG ;
  tapstream.py aligne windows DBG x records tap : sum(T)==records OK partout) : (a) FLOT BL vs BL (t7 vs t8) :
  premier token accepte divergent a pos 3090 (8884 vs 24860) ; avant = flux identique. (b) FLOT BL vs B (t9 vs t7) :
  Premier token accepte divergent a pos 2819 (22916 vs 1596) - DANS LE THINKING, bien avant la fenetre (3081,T=9)
  et avant tout flip visible de la reponse. (c) tapdiff t7 vs t8 (meme flux jusque 3090) : record (3081,1332) row 0
  floats identiques cross-boot jusqu'a tap 5, tap 6 (GDN) deja different max rel 3.4e+01 - dans t7 cette rangee est
  row 0 d'une fenetre T=9, dans t8 row 0 d'une fenetre T=4 : MEME rangee-meme entrees committees, sorties post-layer-6
  DIFFERENTES selon SHAPE de fenetre (9 vs 4) = mesure directe de la dependance numerique a la shape (row 0 ne
  depend d'aucune rangee superieure : pas de carry possible, sauf etat GDN contamine par une fenetre T>=9 ANTERIEURE
  - a trancher : premier T>=9 de t7/t8 vs 2819). (d) t9 (B) n'a AUCUNE fenetre T>=7 (max 6, suffix+spec6).
  HYPOTHESES EN PRESENCE (non exclues) : H1 numerique-shape des kernels >=9 (reduction/tiling differents) ; H2
  effet de bord du knob a T<=8 (gated_proposal force OFF quand STRATA_SPEC_LONG=1 - generate.cpp:2779-2780, actif
  en copie/pas en prose : expliquerait B-vs-BL a 2819 SI T>=9 commence apres 2819) ; H3 course expert-cache (affaiblie
  : t7/t8 floats identiques sur ~1100 positions malgre threads de cache - mais evictions concurrentes possibles).
  ANCIENNE ACQUISITION A REINTERPRETER : "prose B==BL byte-identique" (seed 405) = les fenetres >=9 et gated_proposal
  ne s'activent pas en prose - ne couvre donc PAS le cas copie. PROCHAINE ETAPES : (1) premier T>=9 exact de t7/t8
  (grep DBG) ; (2) lire le code gated_proposal/forced-off (generate.cpp:2770-2790) ; (3) eventuellement boot t10
  STRATA_SPEC_LONG_MAX=8 pour separer effet-knob vs fenetres-longues.

- 2026-10-31 (reprise 2) - MESURE TAP #2 (t5/t6 taps FINS 0..46, 47 layers, copie seed402, 2 boots ; + re-analyse
  t1/t2 avec tapwin.py) : premier record (pos,token) IDENTIQUE a floats differents = idx 438 pos 3066 (t5/t6) et
  idx 457 pos 3081 (t1/t2) - zone pos ~3050-3080 dans les DEUX paires ; t5/t6 = 6000 tok tous les deux mais TEXTES
  differents (byte 1447 de la reponse) et floats divergents des le pos ~3066 : la corruption entre AVANT le flip du
  flux (le commit propage l'etat contamine jusqu'au flip, plus loin dans la reponse). Localisation de couche
  (t5/t6, 47 taps) : taps 0..10 IDENTIQUEs, tap 11 = 2560/2560 floats differents (max rel 1.9e+01) ; pair grossier
  t1/t2 coherent (layer 5 identique, 15 different). geometry.hpp:75-77 : is_qsa_layer = layer % qsa_interval ==
  interval-1 -> avec interval 4 les layers QSA = 3,7,11,15... : la premiere couche divergente (11) est une couche
  ATTENTION QSA, les QSA 3 et 7 de la MEME fenetre sont corrects. CAVEATS declares : (a) le detecteur "runs de pos
  consecutifs" de tapwin.py ne separe pas les fenetres adjacentes quand toutes les rangees sont acceptees (T=24/52
  impossibles, cap 12) - les fenetres reelles ne sont pas connues ; (b) facteur confondant ECARTe : si l'entree de la
  rangee 0 est identique (state commit + tokens identiques upcast aux taps pres), la shape de fenetre ne DOIT pas
  changer ses activations 0..10... l'activation row0 post-layer-11 qui diffine = violation de losslessness vs
  shape OU course dans la fenetre. (c) le tap complet n'a pas masque la divergence (donnees OK). PROCHAINE MESURE
  (DECISION) : etendre l'impression STRATA_DBG_LAUNCH (deja env-gated, verify.cpp:3003-3010) pour loguer (pos0, T)
  a CHAQUE stage_inputs, rebuild, 2 boots t7/t8 (taps 47 + DBG) pour connaitre la sequence REELLE des fenetres
  (T et pos0) autour de 3040-3080 et la comparer entre boots - si les 2 boots ont des fenetres T<=8 la mais que
  l'une a une fenetre >=9 ailleurs qui a contamine l'etat -> carry-over ; sinon course dans la fenetre en cours.

- 2026-10-31 (reprise 2) - MESURE TAP #1 (t1/t2, BL cap12 qw1-BL.json, taps 5/15/25/35/45, copie seed402, 2 boots,
  tapdiff.py) : divergence reproduite cross-boot (t1 garbage 5660 tok "965.332emark?" ; t2 complet 6000 ; txt diff
  byte 4814). PREMIER RECORD (pos,token) IDENTIQUE dont les floats different : idx=457 pos=3081 tok=1332 = RANGEe 0 de
  sa fenetre ; les 5 rangees de la fenetre PRECEDENTE (pos 3080..3084, tokens 16097x5, draft rejete) sont byte-identiques.
  Dans ce record : tap layer 5 IDENTIQUE, tap layer 15 ENTIEREMENT different (2560/2560 floats, max rel 9.7e+01 =
  VALEURS PIGOUBELLES, pas de l'arrondi 1e-3 du mixing CPU/GPU). INTERPRETATION (mesuree) : l'entree de la fenetre
  (embeddings + layers 0..5 en row 0) est identique cross-boot ; la divergence entre dans la fenetre ENTRE les layers
  5 et 15 sur la row 0, en contexte profond (pos 3081 > 2051 ou la selection QSA devient reelle) - confirme le bisect
  "contexte profond requis" et LOCALISE. Cela affaiblit fortement le mecanisme "arrondis expert-cache" (erreur attendue
  ~1e-3, observee ~100x) et renforce course/OOB cote device ou staging des fenetres. NOTE methodo : le tap n'a PAS
  masque la divergence (Heisenbug rejete pour cette sonde). PROCHAINE MESURE : taps fins 6..14 (2 boots t3/t4) pour
  encoder la couche exacte et le sous-systeme (attention/QSA vs GDN vs experts) ; puis instrumenter le noyau trouve.
  Fichiers : tap1.bin tap2.bin (STAP N=2560 nt=5), tapdiff.py, t1.txt t2.txt.

- 2026-10-31 (reprise 2) - CONSTATS STATIQUES + DECISION (sonde TAP) : (1) expert_parity en echec BASELINE = fixture
  absente ("cannot read expert 0 (layer 0) from pack/full/experts.bin"), AUCUNE claim numerique ; les 12
  native_expert_parity_* PASSent mais ne pretendent PAS la parite bit GPU-vs-CPU : native_expert_parity.cpp:8-13 dit
  explicitement que CPU (vec_dot ggml, act q) et GPU (q8_1) different du reference float par "a few 1e-3 relative"
  (tolerance 3e-2) -> le melange hit(GPU)/miss(CPU) change bien les VALEURS, mais une erreur de pure numerique
  DETERMINISTE ne peut pas expliquer la non-determinisation cross-boot a etat de boot identique (meme profil, meme
  remplissage 11686 experts 22.17 GiB - logs B1a/B1b vs BL : hit 97.7-98.1%, +0.4% PCIe). DONC : course (timing) ou
  lecture non initialisee, comme deja oriente par le bisect. (2) audit rows>=8 (suite) : stage_inputs remplit bien
  h_pos_/pk/pi pour t<T (verify.cpp:2982-2989, buffers dimensionnes max_t a 876/973) ; region batch 4439-4459 =
  chemin batch (rows<=8 par design) ; rien de neuf hors survivants deja notes. (3) DECISION de sonde : STRATA_TAP_FILE
  + STRATA_TAP_LAYERS (verify.cpp:893-928, ecrit par tap_write 764-774 : 1 record par RANGEe de fenetre = pos int32,
  token int32, nt x n_embd floats au layer tap ; serial only lb_=0 le_=n_layers = notre parallel=1) : 2 boots BL
  cap12 (qw1-BL.json, STRATA_SPEC_LONG=1) avec tap 5,15,25,35,45 + copie seed402, PUIS parseur : premier record
  (pos,token) identique dont les floats different = ou entre le bit divergent ; index du premier tap divergent =
  encadrement de la couche ; rang de rangee (<8 ou >=8) = discriminera stage/rows-longs vs chemin partagé. CAVEAT
  declare : le tap ajoute une copie DtoH par fenetre (2577) - s'il FAIT DISPARAITRE la divergence, c'est une info
  (Heisenbug = course de timing). Fichiers : gate1/tap1.bin tap2.bin, parseur tapdiff.py. ASAN revisit NON retenu
  (build-asan du 30/10 mort au pin embedding 322 MiB "out of memory", 56 GB+shadow vs 121 Go RAM).

- 2026-10-31 (reprise 2) - MESURE + CONSTAT BLOQUANT (sonde expert-cache OFF, etape 1bis) : boot nca (qw1-BL-nocache.json,
  --expert-cache 0 sans profile) - NON EXECUTE jusqu'a la requete : le moteur REFUSE le demarrage avec spec, message
  "strata serve: verify: needs the profile-filled VRAM expert tier" ; cause VERIFIEE file:line : Verifier::init exige
  hits.cache_base != nullptr (src/core/verify.cpp:832-838) et cache_base n'est alloue QUE si expert_cache > 0
  (generate.cpp:7710). DONC sans VRAM expert tier il n'y a PAS de verify du tout : la sonde "cache OFF" est IMPOSSIBLE
  sur le chemin spec/BL sans toucher au code. Probe consommee 1 boot (~4 min, engine mort de lui-meme, GPU revifie vide
  4 MiB, orphelins verifies). PISTES alternatives NON ENCORE EXECUTEES : (a) --expert-cache-cpu-order
  (generate.cpp:3302, "GPU expert reduction matching CPU order") ; (b) STRATA_VERIFY_ALL_RESIDENT (verify.cpp:1167) a
  lire d'abord ; (c) expert_parity = echec BASELINE preexistant : le relancer seul pour voir s'il dit que hits GPU !=
  misses CPU en bits pour IQ3_S (si oui = le mecanisme mixing a du grain ; si identiques en bits = mecanisme affaibli,
  retour aux rows>=8) ; (d) noté : STRATA_PREFILL_CPU_SHARE (documente au boot, "answers can differ slightly") est
  hors-cause pour la non-determinisation (B deterministe cross-boot malgre prefill CPU share identique).

- 2026-10-31 (reprise 2) - DECISION (etape 1 du plan de finition, sonde expert-cache OFF, PROCHAINE SONDE CHOISIE du
  rapport final) : flags reels VERIFIES file:line dans le moteur 0.1.53 : pas de --no-expert-cache ; le disable propre =
  RETIRER --expert-profile ET mettre --expert-cache 0 (generate.cpp:5105 : le 0 n'est remappe en auto QUE si un profile
  est present ; guard 7710 : la hit-path GPU (xcache, d_hit_*) n'existe qu'avec expert_cache>0 ; prefill borrow 17473 =
  nullptr sans cache). FAIT Utile VERIFIE : generate.cpp:7716-7718 (R4.2h) documente QU'UN DESACCORD fp16-vs-fp32 de
  4.761e-04 entre hits GPU et misses CPU sur les scales d'activation "est la raison pour laquelle activer le cache a
  change les tokens" - le melange CPU/GPU change le output dans CE moteur aussi (corrige pour les scales seulement,
  parite GPU-vs-CPU complete NON etablie ; noter que expert_parity est un echec BASELINE preexistant). PROTOCOLE :
  config qw1-BL-nocache.json = qw1-BL.json SANS --expert-profile ET --expert-cache 0, tout le reste identique
  (parallel=1, reserve 1500, spec 6+suffix 3) ; env STRATA_SPEC_LONG=1 (cap 12 par defaut) ; 2 boots x copie seed402
  2200 mots greedy maxtok 6000 (copy_only.py) : attendu (a) nocache-a vs nocache-b = determinisme BL sans cache ;
  (b) vs B1a/B1b (temoin byte-identique existant) = losslessness. Si nocache deterministe ET == B1 -> mechanisme =
  melange arrondis CPU/GPU de l'expert-cache (amplifie par evictions non deterministes en decode) - NON VERIFIE
  jusqu'ici. Si divergence persiste -> retour hypothese etat/corruption rows>=8. Coste : decode tout-CPU attendu plus
  lent (chiffre = cadence, pas qualite). Tuage par PID apres chaque boot (serve+engine+strata-vision), GPU verifie vide.
  Etat verifie en reprise : HEAD 46c152a1 sans commit local, 20 fichiers modifies, GPU 4 MiB, strata.service inactive,
  seul strata-watchdog (2036) vivant (inactif tant que le service ne l'est pas).

- 2026-10-31 (suite) - DEMANDE OPERATEUR (audit puis reprise) + CONSTAT Phase 3 (git, read-only) : HEAD f-qwen-lookup
  base = main 46c152a1 = moteur 0.1.53 ; origin/main amont = c62d5e3a = v0.2.9 (moteur 0.1.55) = 239 commits de retard.
  Chevauchement du diff (20 fichiers, +563/-201) avec l'amont : generate.cpp touche par 14 commits amont, verify.cpp 6,
  verify_kernels 2. DECISION PROPOSEE (non appliquee, en attente d'accord) : NE PAS rebaser maintenant (le bug de
  divergence T>=9 est ouvert ; rebaser 563 lignes non commitees sur 239 commits multiplierait les variables ; la regle
  amont de compare same-day se fera au moment de la PR). Fetch execute (lecture seule, aucun push, aucun commit a ce
  jour). FAITS utiles de la release 0.1.55 pour nous : "Qwen3.6 warmup ecrivait au-dela du KV" (#4708) = famille de
  nos bugs ; "DeepSeek non reproductible a temperature 0 cause expert cache CPU<->GPU (arrondis differents)" =
  MECHANISME DOCUMENTE EN AMONT qui pourrait amplifier notre non-determinisme BL (NON VERIFIE pour Qwen) ; defaults
  parallel (STRATA_QSA_SLOTS etc.) = a verifier au rebase. ABBA (etape 5) : NON EXECUTE (coupe pendant boot B).

- 2026-10-31 (suite) - MESURE (sonde nomtp) + DECISION (ABBA) : BL SANS MTP (qw1-BL-nomtp.json, cap 12, 2 copies seed402)
  = DIVERGENT et NON DETERMINISTE aussi (bytes 585/442, 10 captures 10..12) -> MTP HORS DE CAUSE. STRATA_DEC_BATCH=0
  (cap12) : divergent egalement et non deterministe -> pas un kernel batche specifique. Commit indexer_layers (MT=12)
  relu : boucle sur n_steps sans plafond 8 (native_qsa_indexer.cu:300-340) - rien de trouve la. Le bug de losslessness
  reste OUVERT, surface reduite : T>=9 seul, MTP hors cause, batching hors cause, contexte profond requis (position
  > ~2051 ou la selection QSA devient reelle vs identite en court), non deterministe meme boot. Prochaine mesure due au
  plan : ABBA vitesse (bench_qw1.py, seed 401, 4 boots alternes B BL BL B, parallel=1 des deux bras - les bras Gate 1
  etaient en parallel=2, B est REMESURE ici). La vitesse BL est mesuree sur des copies qui divergent - le chiffre est
  une cadence machine, pas une validation qualite ; a declarer comme tel dans le rapport.

- 2026-10-31 (suite) - AVIS sous-agent deepseek #2 + VERIFICATION : hypothesis proposee = capacite des slots KV-streaming
  (contrat n_slots = n_q*(cap/page+2) dimensionne pour 8 requetes, min resident 20480 cellules, layer.cpp:752/771,
  contrat kv_stream.hpp:86-88, width 2051 qsa.hpp:133) -> deborde a T>=10 avec page 4 : REJETEE pour NOS TESTS par
  verification statique+logs : avec --max-context 16384 (4096 pages) et le plancher 20480 (5120 slots) > pages,
  kv_plan rend mode 0 (full resident) et AUCUNE ligne "KV streaming:" n'apparait dans les logs des boots -> streaming
  JAMAIS actif dans nos runs. RESTE UN RISQUE REEL NON VERIFIE POUR LA PROD (--max-context 262144 : pages 65536 >
  5120 -> mode 1) ou le contrat de slots suppose n_q<=8 alors que max_t_=12 : a signaler/gerer avant PR.
  Fait verifie par la meme occasion : le mini-repro propre s'explique partiellement - en contexte court (< ~2051 cellules)
  la selection QSA est IDENTITE (qsa.hpp: note 2,051) donc les kernels de selection/top-k des rows 8..11 ne sont pas
  sollicites pareil qu'en contexte profond. Sonde DECISION : boot BL cap12 avec STRATA_DEC_BATCH=0 (chemin fenetre
  non-batche token par token partout) + copie seed402 : si byte-identique a B1 -> le bug est dans un kernel BATCHE de
  la fenetre longue (QSA batch gemv_cols/norm_rope/indexer_append_steps/scores/topk ou mm_cols) -> bisect ensuite
  STRATA_DF_QB_Q4=0 / STRATA_SIDE_MIXER / STRATA_DF_BRANCH ; si diverge -> host-side (commit/policy) ou non-batche.
  Note: pkill du launcher python a orpheline le moteur dsv41 (985115) tu par PID ensuite - GPU revifie vide avant boot.

- 2026-10-31 (suite) - MESURE (bisect cap, knob debug STRATA_SPEC_LONG_MAX ajoute a generate.cpp:2779-2784 + 5 sites,
  defaut = kVerifyLongT donc comportement unchanged) : cap 12 (2 boots + 2e requete meme boot) : divergence avec B1 a
  chaque fois, POSITION QUI BOUGE (bytes 5756, 6076, 5720) - le bras BL est NON DETERMINISTE cross-boot ET meme boot,
  alors que le bras B est byte-identique cross-boot (temoin). cap 10 : diverge (byte 1142 = ~mot 190) et non deterministe.
  cap 9 : diverge (byte 6623) et non deterministe. DONC : le bug est declenche par T=9 seul (pas besoin des chunks 8+4
  de 12) ; surface en cause = instanciations GDN <12,false> utilisees des T=9, chunking 8+1 des projections denses
  (mm/quantize record_window), tableaux elargis, propose long/agree2, chemin pipelined pl_* - et la NON-determinisation
  (meme boot) oriente COURSE ou LECTURE NON INITIALISEE, pas une erreur numerique fixe ; la perte survient en contexte
  profond (position ~2600+) mais pas en contexte court (mini-repro fenetres 9..12 immediates = byte-identique a B).
  DECISION : avis du sous-agent deepseek (258K) sur les chemins verify/commit/replay des lignes 8..11 (le sous-agent lit
  le code, moi je verifierai chaque claim), puis sonde dirigee. NE RIEN changer avant la verification des claims.

- 2026-10-31 (suite) - MESURE + DECISION (etape 4 suite) : mini-repro (24 mots x3, maxtok 900) BL vs B = BYTE-IDENTIQUE
  ET fenetres 9..12 reellement capturees sur le boot BL (le log est appendu : captures avant la ligne du boot B = boot BL ;
  le boot B n'en capture AUCUNE, cap 8). DONC le chemin 9..12 est sans perte en CONTEXTE COURT. Sur la copie 2200 mots,
  divergence au MOT 934 (B continue 'numbers dry fox...', BL emet le token poubelle 'numbersegl?' puis fin a 935 mots;
  0 crash). Le bug depend de la position/du contexte profond, pas de la seule presence d'une fenetre longue.
  DECISION de bisect : knob DEBUG STRATA_SPEC_LONG_MAX (plafond runtime 9..12 quand STRATA_SPEC_LONG=1, defaut 12, hors
  chemin par defaut) - boots BL avec cap 10 puis cap 9 : si propre -> lignes 11..12 en cause ; si diverge -> lignes 9..10.
  Puis DeepSeek sous-agent sur les chemins qui ne dependent qu'ici (replay GDN/PLE/K-V des lignes 8..11 en contexte long,
  pl_stage/pl_commit pipelined, eviction pendant decode ~930 MiB libres).

- 2026-10-31 (suite) - MESURE (etape 4 identite) : 3 boots parallel=1 seed 402 copie 2200 mots greedy 6000 tok.
  Temoin determinisme B : B1a (boot1) == B1b (boot2) OCTET POUR OCTET. prose (seed 405, meme prompt) B vs BL :
  IDENTIQUE (le bloc long ne declenche pas hors copie - conforme au design). Copie B1 vs BL1 : DIVERGENCE au byte 5756
  (BL1=5665 tok vs B1=6000) avec 0 crash et fenetres longues reellement utilisees (12 capturees 11x, histogramme
  accepted/tested etend au-dela du bucket 4). DONC la perte de losslessness est un bug NUMERIQUE/DECISIONNEL propre
  au chemin 9..12, distinct du crash A (le crash n'etait pas la cause du garbage). NOTE (B1 seul) : la copie B diverge
  d'elle-meme du document a partir du mot ~1217 (comportement modele sur ce doc) - BL1 suit B1 jusqu'au byte 5756 puis
  s'en ecarte : la divergence BL est dans la zone de decrochage, la ou les brouillons deviennent faux et les fenêtres
  butent au plafond. Prochaine etape : minimiser (repro_long 24x3 sur 1 seul boot par bras, comparison B vs BL), puis
  isoler (les chemins chunkes 9..12 sont les seuls nouveaux : mm/quant record_window, GDN dispatch <12>, MTP clamp,
  agree2, policy propose). Lecon regle appliquee : le pkill + la reference unquoted au config dans la MEME commande
  s'entretuent (pattern qw1-BL.json matche le cmdline du shell) - toujours separer.

- 2026-10-31 (suite) - MESURE (parite + ctest) : (a) le nouveau cas shared_expert_multi (12 rangees, pattern production
  8+4 avec offset q8_1 vs oracle 12x n=1, et oracle n=4 rows 8..11) = BYTE-IDENTIQUE (shared_expert_parity 0 failure) -
  le cas marque NON EXECUTE le 2026-10-30 est desormais EXECUTE et PASS. (b) ctest complet apres le correctif
  last_tokens_/kHistSlots : en -j4 = 7 echecs dont expert_cache_segmented_test, qui PASSE seul (0.25 s) = contention
  parallelite ; en -j2 = exactement les 6 echecs de la baseline preexistante (ple_parity, platform_memory_test,
  expert_parity, pool_test, isa_guard_check, cuda_spill_guard). PAS de regression. Prochaine etape (4) : identite
  B1 vs BL1 copie seed 402 (2200 mots, greedy, parallel=1) : boots separes B (sans STRATA_SPEC_LONG) x2 = temoin de
  determinisme, BL (STRATA_SPEC_LONG=1) x1, cmp octet a octet ; plus prose 400 tok B vs BL = attendu inchangee (le bloc
  long ne doit pas declencher hors copie).

- 2026-10-31 (suite) - DECISION (etape 3 du plan de finition, parite shared_expert multi): le cas "shared_expert_multi
  n=12 vs 8+4" etait NON EXECUTE (Decision Log 2026-10-30 11:3x). Verifie: shared_expert_multi refuse n>8 (contract
  1..8, shared_expert.cu:220) - le chunking est cote APPELANT (verify.cpp:2228-2243, nsw2.q8_1 += cb*(N/32)*36) et
  shared_expert_parity.cpp ne couvre AUCUN chemin multi. TEST AJOUTE dans src/kernels/shared_expert_parity.cpp (meme
  cible ctest, pas de nouveau fichier): 12 rangees x n_embd=256/n_ff=64, poids Q4_0 (type 2) aleatoires a echelle fp16
  0.002 (finis garantis), x gaussien; (A) miroir EXACT du pattern production: pass n=8 puis cb=8 n=4 avec q8_1 decale
  de 8*(N/32)*36; (B) oracle par token: 12 appels n=1 scratch separe; (C) oracle un seul appel n=4 pour rows 8..11.
  Attendu: A==B byte-identique (memcmp) et C==B rows 8..11 byte-identiques; un NaN/inf dans la sortie = fixture hors
  plage signale. Chemins production non touches (test seul).

- 2026-10-31 (suite) - MESURE (crash A RESOLU - 6e correctif de la famille) : build A (instrumentation seule,
  STRATA_DBG_LAUNCH dans stage_inputs) -> repro x1 : lignes BEFORE montrent n_vocab_=248320 SAIN au T=12 et T=10, puis
  CORROMPU (319781790271725 = 0x000122d7_0003c8ed = PAIRE de tokens = tokens[8]|tokens[9]<<32) aux T=9/T=11 SUIVANTS ;
  exit -11 dans le .server.out. Les lignes AFTER manquent (buffering stderr perdu au crash). Build B = correctif
  last_tokens_[8] -> last_tokens_[kVerifyLongT] (include/strata/core/verify.hpp:594) + kHistSlots penalty -> kVerifyLongT
  (generate.cpp:9885, surverse reelle seulement si penalty_last_n grand, default 0) + commentaire set_history corrige +
  fflush sur le dbg. Repro x3 sur build B : 0 exit -11 ; 12 fenetres longues utilisees (T=12 x4, T=11, T=10, T=9),
  AVRES et APRES chaque stage cs_ et n_vocab_ intacts. CAUSE ETABLIE PAR MESURE (pas seulement statique).
  NOTE : runs 2/3 = tok=700 contenu vide = thinking-cutoff connu (6 lignes thinking:), pas un crash ; run 1 = copie
  complete correcte. Le garbage BL1 (perte de losslessness) est probablement la MEME cause (cs_/n_vocab_ ecrases par les
  tokens de la fenetre) - a confirmer par l'identite B1 vs BL1 (etape 4). Survivants signales par le sous-agent DeepSeek
  notes pour la PR (hors serveur) : generate.cpp:18131-18139 window/outv/accepted_hist tailles o.spec avec T jusqu'a 12 ;
  backtrace() debug residuel dans native_mmvq.cu:2310-2315 a verifier. Prochaine etape : ctest complet vs baseline 6 echecs,
  puis test de parite shared_expert_multi n=12 vs 8+4 (etape 3, jamais execute).

- 2026-10-31 (suite) - SOUS-AGENT deepseek (tentative 3, 258K OK) + VERIFICATION CONTRE CODE (regle: DeepSeek jamais une
  autorite) : le claim principal est CONFIRME par lecture directe. last_tokens_[8] (include/strata/core/verify.hpp:593) est
  SUIVI de n_vocab_ (594) puis cs_ (595, cudaStream_t passe a chaque cudaGraphLaunch). La boucle sans garde
  "for (t=0;t<T;++t) last_tokens_[t]=tokens[t]" (src/core/verify.cpp:3003, stage_inputs appele par run/pipelined/prelaunch,
  T jusqu'a 12 en mode long) ecrit 16 octets hors du membre : idx 8-9 -> n_vocab_, idx 10-11 -> les 2 moities de cs_ ->
  cudaGraphLaunch(exec, cs_) avec un stream dechire = signature exacte du SIGSEGV dans cuGraphLaunch (mov (%rdx)).
  C'est la 6e survivante de la famille "tableau dimensionne 8 indexe jusqu'a 12" - non vue dans le git diff car la ligne
  n'etait pas modifiee. CONFIRME aussi (second claim) : kHistSlots = kPenaltyWindowCap*kVerifyMaxT (src/program/generate.cpp:9885-9889)
  surverse si penalty_last_n grand et T>8 (hist_n=0 par defaut -> non declenche dans nos tests, a corriger quand meme avant PR).
  NUANCE (incoherence relevee par DeepSeek, non resolue) : un run parallel=1 a fait 27 launches T=12 sans crash (2026-10-30 11:3x,
  binaire anterieur) - la corruption de cs_ aurait du crasher a chaque coup ; possible selon l'etat memoire du driver -> a trancher
  par MESURE avant d'affirmer la causalite. PLAN D'ACTION : (1) build A = instrumentation env-gated STRATA_DBG_LAUNCH dans
  stage_inputs (cs_ et n_vocab_ AVRES/APRES la boucle quand T>8) SANS correctif -> repro x2 pour DEMONTRER la corruption ;
  (2) build B = correctif last_tokens_[kVerifyLongT] + kHistSlots kVerifyLongT -> repro x3 attendu 0 crash. Chemin par defaut
  inchange (T<=8 n'ecrit jamais au-dela de 8 ; taille de membre seule). Le sous-agent signale aussi des survivants dans le
  chemin generate (generate.cpp:18131-18139 window/outv/accepted_hist tailles o.spec avec T jusqu'a 12) - notes, hors serve,
  a corriger avant PR. DeepSeek signale un backtrace() debug residuel dans native_mmvq.cu:2310-2315 - a verifier/retirer.

- 2026-10-31 (suite) - CONSTAT: relance DeepSeek faite, variante /tmp/opencode/qwen-lookup/serve-ds4-258k.json loaded:true,
  max_context 258048, host 0.0.0.0, 30 s de boot, GPU 31.6 GiB, RAM 114/121 Go. Tentative 3 du sous-agent deepseek
  (analyse du crash cuGraphLaunch, lecture du depot, aucune modification) lancee APRES cette entree.

- 2026-10-31 (suite) - DECISION (operateur): la 2e tentative du sous-agent deepseek a echoue aussi (compaction permanente) :
  l'instance DeepSeek etaitservee avec --max-context 16384 (config officielle) -> fenetre trop petite pour le contexte du
  sous-agent. L'operateur demande 258K (258048). Relance avec une VARIANTE de config (/tmp/opencode/qwen-lookup/serve-ds4-258k.json,
  config officielle copiee, --max-context 16384 -> 258048, host 0.0.0.0 ajoute) pour ne pas toucher la config officielle.
  Kill par PID 940101 d'abord, GPU verifie vide, puis sante /health max_context attendu = 258048.

- 2026-10-31 (suite) - CAUSE DE L'ECHEC DU SOUS-AGENT deepseek (verifiee, pas une cle API) : le provider SysAi2.Strata
  (opencode.json:77-78) pointe sur http://10.2.75.12:8080/v1 mais le serveur DeepSeek etait LIE A 127.0.0.1:8080
  (ss -ltnp ; config strata-deepseek-v4.1-flash-ist-das-2.25bpw.json sans cle "host" -> server.py:8813 met 127.0.0.1 par
  defaut) -> connexion refusee (HTTP 000) sur l'adresse 10.2.75.12. La cle du provider est ignoree par le serveur (api_key
  false) donc sans objet. DECISION : relancer l'instance DeepSeek avec --host 0.0.0.0 (flag existe, server.py:8658),
  tuer par PID 937401/937407 d'abord, verifier GPU vide, puis retenter le sous-agent. Re-test curl sur 10.2.75.12 AVANT relance du sous-agent.

- 2026-10-31 (suite) - CONSTAT (verifie file:line) + DECISION : l'etape 1 du plan de finition (sonde STRATA_FUSE_CONVAB=0) est
  INVALIDE sur cette machine : fuse_convab_on() (src/core/verify.cpp:467-473) ne lit l'env que sous #if STRATA_USE_HIP et
  retourne false sinon -> no-op sur le build CUDA 5090. Sonde SAUTE, non consomree. Verifie aussi : 12 appels cudaGraphLaunch
  (grep verify.cpp : 3135 prelaunch, 3242 run serial, 3758/5143 commit_exec_, 4167-4665 batch, 4978 run pipeline serve) ;
  instantiate_evicting (4357) peut detruire les exec_ d'AUTRES tailles de fenetre (evict_window_graph 4240, stream-sync puis
  cudaGraphExecDestroy) quand une capture 9..12 manque de VRAM -> les graphes 1..8 pre-captures au boot peuvent etre EVICTES
  par la capture de 9..12 (VRAM ~930 MiB libres au boot prod) = retour a la capture lazy en milieu de requete, ce qui pourrait
  expliquer l'inefficacite de la pre-capture. Prochaine etape : avis DeepSeek (instance deja chaude) avec extraits de code,
  puis instrumentation STRATA_DBG_LAUNCH (site + T + pointeur exec avant chaque launch) pour identifier le launch qui meurt,
  puis cap 10. Aucune cause retenue sans mesure.

- 2026-10-31 08:10 - DECISION (second avis DeepSeek): le sous-agent deepseek passe par le provider SysAi2.Strata
  = http://10.2.75.12:8080/v1 (trouve dans ~/.opencode/opencode.json:77) -> il faut servir DEEPSEEK sur 8080.
  Config officiel utilisee : strata-deepseek-v4.1-flash-ist-das-2.25bpw.json (exe engine-dsv41/0.1.52, pack
  ist-das 2.25bpw, model_name deepseek-v4.1-flash). (Correction : le chemin /tmp/opencode/qwen-lookup/serve-ds4.json
  cite dans le prompt de reprise etait invente - ne pas le repeter.) Qwen de test tue avant. Arretre DeepSeek quand fini.

- 2026-10-31 07:20 - REGLE (utilisateur): tuer tous les process strata (serve/server.py, engine/strata, gdb wrapper, strata-vision orphelins) AVANT chaque test, sauf si le test exige l'instance deja chaude. Verifier pgrep + nvidia-smi vides avant de relancer. (Les orphelins vision/gdb encombrent la VRAM et font echouer les lancements.)
- 2026-10-31 07:20 - CONSTAT gdb (crash 9/12): backtrace certaine = Thread 1 strata-host: cudaGraphLaunch -> cuGraphLaunch (libcuda) SIGSEGV, appele depuis Verifier::run (frame #6), thread principal; aucun autre thread dans libcuda au moment du crash (les autres dorment) -> la course concurrente au moment du launch n'est pas prouvee. La precapture 1..12 au demarrage est active et ne change pas le crash. Prochaine etape: instrumenter cudaGraphLaunch (log env STRATA_DBG_LAUNCH: taille T + pointeur exec) pour savoir QUEL launch meurt.

- 2026-10-30 20:10 - DECISION (recherche web + fix capture): recherches web - famille exacte trouvee : minfer #185/#188 (SIGSEGV libcuda quand cudaGraphInstantiate/capture chevauche des cudaMemcpy/cudaFree d'un autre thread, non stream-ordered; fix = discipline de capture) et vllm #54331 (sm_120 + GDN + CUDA graphs = segfaults sous charge, enforce_eager survit). Dans Strata: la capture paresseuse des tailles 9..12 a lieu EN MILIEU de requete pendant que le thread I/O de l'expert-cache deplace des experts (cudaMemcpy/Free) - les tailles 1..8 sont capturees tot, les longues tard -> correlate avec le declencheur du crash. Fix: pour STRATA_SPEC_LONG, appeler Verifier::capture_all (deja utilise par --pipeline-windows, 'captures everything while nothing is in flight') au demarrage du serve, avant la 1re requete (opt-out STRATA_PRECAPTURE=0). Chemin par defaut inchange (la longue est déjà opt-in). Test: repro x3 + copies x2 sans EAGER: attendu 0 crash.

- 2026-10-30 19:10 - OBSERVATION + DECISION : le preload des kernels <12,false> n'empeche pas le crash (bl19: 4 exit -11; repro #3 passe). Prochaine sonde structurelle (patch propose par l'agent general, non applique jusque la): desactiver les branches laterales DANS LES FENETRES LONGUES uniquement (side_mixer/side_proj/shared-expert fork sur streams secondaires quand T>8) - les sorties sont bit-identiques (meme kernel, juste inline, commentaires 1605/248). Si le crash disparait: course =并发 inter-streams dans le graphe long; sinon: piste eviction/instantiate (VRAM ~930 MiB libres, evictions frequentes).

- 2026-10-30 18:20 - DECISION (fix crash A, hypothesis strongest): dump DOT du graphe T=11: structure correcte (toutes les passes 8+3 presentes, pas de grid nulle) -> le graphe n'est pas malforme. Le crash survient au PREMIER lancement des fenetres 9..12 et seulement la, CUDA_MODULE_LOADING=EAGER (bl8) avait donne 0 crash sur 6 requetes avec fenetres longues actives. Hypothese: lazy module-load des instanciations nouvelles gdn_conv_ab_kernel<12,false>, gdn_ab_multi_kernel<12,false>, gdn_state_replay_kernel<12> pendant cudaGraphLaunch, en concurrence avec les lancements du pipeline -> course dans libcuda (statique non confirme, precedents cites par l'agent general: #905/#2403 "first verify graph launch"). Fix: cudaFuncGetAttributes (force le chargement du module) sur ces 3 instanciations a l'init du Verifier, appelee UNIQUEMENT quand max_t_ > kVerifyMaxT (chemin par defaut byte-identique). Test: repro 3x24 mots x3 sans EAGER ni MAX_CONNECTIONS: attendu 0 crash.

- 2026-10-30 17:05 - DECISION : le mini-repro (3x24 mots, copie) fait crasher le engine (SIGSEGV) au premier lancement du graphe 11-token (bl14) ; bl9 avait survécu a la capture 11 avec garbage -> instable, declencheur = premiere utilisation du window 11. Sonde ajoutee (debug derriere env STRATA_DBG_DOT, hors chemin par defaut) : cudaGraphDebugDotPrint verbose du graphe capture (T=8 reference vs T=11/11 suspects) pour comparer les nœuds et parametres des lancements chunkes n>8.

- 2026-10-30 16:40 - OBSERVATION + DECISION : avec STRATA_MMVQ_IL=0 (bl10) la copie r1 est byte-identique a B1 (plus de garbage) mais 11 crashs -11, chacun immediatement apres `capturing the 11-token window` (bl9 il=1 : 0 crash, garbage a ~2741). Le lien il<->crash est probablement du timing, pas une cause directe. Sonde : CUDA_LAUNCH_BLOCKING=1 (diagnostic uniquement) x3 copies avec il=0 : si crash+garbage disparaissent -> course inter-threads/graphs dans la fenetre longue ; sinon -> corruption memoire independante du timing. Process stale tues (serve 806391 + strata-vision 806394).

- 2026-10-30 15:50 - DECISION (cause probable racine du crash et du garbage BL1) : lecture code, la voie decode pipelinee (pl_stage/pl_launch, utilisee par serve) remplit `pl_ple_rows_` (src/core/verify.cpp:4903, dimensionne kVerifyMaxT=8 lignes) pour t=0..T-1 avec T jusqu'a 12 -> ecriture hors du vector (4 lignes x PLE_N_HEADS uint32) -> corruption du tas hote : explique tokens poubelle non deterministes + SEGV cuGraphLaunch (le driver alloue dans le meme tas) + correlation avec la capture des fenetres 11/12. Fix : dimensionner pl_ple_rows_ a max_t_ (8 inchange pour les configs existantes, donc chemin par defaut byte-identique). Fix accompagne : le garde d_spec_ (rejection sampling MTP) reste plafonne a kVerifyMaxT ; passe a max_t_ avec allocation max_t_ lignes (inchange a max_t_=8). A verifier : 6 copies seed 402 sans garbage ni crash, puis identite B1 vs BL1.

- 2026-10-30 15:20 - OBSERVATION + DECISION : la sonde sans MTP (qw1-BL-nomtp.json) crash SIGSEGV deja au warmup, donc la course n'est pas propre a MTP. Le crash survient systematiquement peu apres la capture du graphe 11/12-token. Le split de fenetre (groups_=2, moitie 6+6) depend de `split_` ; l'abort `y[8]` mesure plus tot prouve qu'un drain du pool a recu nt>=9, donc G=1 (fenetre en un seul groupe, n=12) dans la config BL : les chemins chunkes n>8 (quantize/mm_cols/gemv_cols/shared expert, avec leurs forks/joins sur side2_/df_side_) sont les seuls nouveaux lancements. Sonde : STRATA_SIDE_MIXER=0 (supprime les branches laterales) x3 copies seed 402 ; reference bl4 : 1 des 3 copies avec token poubelle.

- 2026-10-30 14:55 - OBSERVATION + DECISION (fiabilité BL1) : apres fix `kTqMaxTokens=12`, un bench BL1 complet finit sans crash, mais l'identite B1 vs BL1 (seed 401/402, copie 2200 mots) DIVERGE de facon non deterministe : 3 runs BL1 -> 1 propre, 1 garbage (token hors document + EOS anticipe), 1 propre ; positions differentes ; B1 est byte-identique a lui-meme. Fenetres 12 capturees ET utilisees avec STRATA_SPEC_LONG_MIN=9 -> output identique a B1 sur ce run (n=1, non concluant). Le crash SEGV `cuGraphLaunch` revient par intermittence (warmup, run 2). Conclusion de travail : course/corruption dans le chemin fenetre longue, pas un kernel statique simple. Prochaine sonde : BL sans MTP (qw1-BL-nomtp.json, meme config sans --mtp) x3 copies pour separer l'interaction MTP x fenetre longue. Aucune affirmation de cause sans preuve.

- 2026-10-30 12:05 - DECISION (phase 2, crash fenetre longue) : sous gdb, le bench BL1 a donne deux familles de crash : (a) `*** stack smashing detected ***` dans `cpu::iq4nl256_down_rows` (table `y[8]` remplie jusqu'a nt=12) - corrige par passes de 8 (bit-exact, chaque token reste dans un seul appel) ; (b) SEGV `cuGraphLaunch` qui persiste apres (a), avec les 15 pool-workers CPU actifs pendant le launch. Cause (b) trouvee par lecture : `kTqMaxTokens = 8` (include/strata/kernels/cpu/tq_cpu.hpp:81) dimensionne `acc[]`, `act[]`, `ptr[]` des kernels trellis (`tq_rows`, `rows_t`) indexe jusqu'a nt=12 -> corruption de pile du pool-worker -> corruption du tas du driver -> SEGV au launch. Action : `kTqMaxTokens` passe a 12 (tous les tableaux se dimensionnent dessus ; les kernels indexent deja `t < nt` en runtime ; le chemin DeepSeek reste a nt<=8, aucun changement de sortie attendu - verifie par tq parity + ctest avant de rejouer le bench). Confirmation attendue : plus aucun crash sous gdb sur le bench seed 401. Marquer comme statique jusqu'au run : le lien exact tas-driver<->cuGraphLaunch n'est pas prouve, seul le depassement de pile est mesure (abort gdb).

2026-10-29 22:3x : CAUSE DES BOOTS BL INOPINANTS : la config serve lance
  `exe: /home/sysops/Strata/engine/strata`, un binaire du 27/10 NON PARCHE :
  bl1/bl2/b1r tournaient sur l'ancien moteur (d'ou histogramsme identique).
  DECISION : backup engine/strata.pre-patch, installe build/strata (0.1.53,
  branche f-qwen-lookup) dans engine/strata. AUSSI : l'arm BL retire
  --batch-mtp (design : bloc long = chemin serial ; le chemin batch-mtp est le
  pipeline A/B/D, fenetres <=8). b1r (defaut) doit etre RE-JOUE sur le binaire
  parche pour etre une baseline valable. Debug env STRATA_SPEC_LONG_DEBUG
  (temporaire, a retirer avant toute contribution).

2026-10-29 21:0x : PROTOCOLE IDENTITE PATCH. Les runs gate 1 utilisaient des
  seeds DIFFERENTS par boot : aucune baseline byte-a-byte stock n'existe, et le
  moteur n'est pas connu deterministe (drafts accepted differents entre boots
  identiques vus dans b1/b1r). DECISION : preuve sur le moteur reel = 3 boots
  MEME seed 401 : bl1 (B + STRATA_SPEC_LONG=1), b1r2 (B), b1r3 (B) ; copier le
  texte greedy complet (RUNTXT) ; exiger bl1 == b1r2 (perte nulle) et b1r2 ==
  b1r3 comme temoin de determinisme (si le temoin differe, la revendication
  byte-identique est declaree impossible sur ce moteur et remplacee par
  "head/tail + tok/s equivalents" + parite unites). Stock-vs-patche reste
  couvert par verify_parity/spec_verify_parity/gdn/s2/resident_plan.

2026-10-29 20:3x : BLOCKER TROUVE PENDANT LA VALIDATION (par l'ext gdn_parity,
  par accident - utile) : native_mmvq.cu a MAX_NCOLS=8 et validate_shape JETTE
  std::invalid_argument si ncols>8. record_window appelle quant_in
  (native_quantize_q8_1 ncols=n) et mm (native_mmvq ncols=n) avec n = rows de
  la fenetre : une fenetre 9..12 aurait fait lever l'exception en capture de
  graphe sur le chemin dense natif (le pack IQ3_S est natif sur la 5090).
  DECISION : chunking des projections denses par paquets de 8 colonnes dans
  record_window (mm + quant_in), un seul appel quand n<=8 (defaut STRICTEMENT
  inchange), les kernels mmvq non touches (pas d'instanciations 9..12 : surface
  trop grande). Chaque colonne est independante dans ces kernels (parite
  verify_parity/iq_multi_parity le prouve pour ncols<=8) - a confirmer par le
  test d'identite greedy off/on. Meme motif corrige dans le harness gdn_parity
  (native_quantize reference chunke). Pieges connexes deja fixes : multi-cpu
  expert default<8 qui Jetait les tokens 9..12 (guard >8 remis, test
  expert_multi_test PASS a re-run), idem gu_rows_multi/down_rows_multi/q2g_rows
  a verifier. Prochaine action : chunking record_window, rebuild, suite ctest
  = baseline main uniquement, puis banc STRATA_SPEC_LONG.

2026-10-29 19:5x : DESIGN PHASE 2 ecrit (section "Phase 2 EN COURS") apres
  cartographie complete (explore + relecture directe des kernels). DECISIONS :
  cap 12 et non 15 (kResidentPlanMax=128 threads, K=10 -> 12x10=120 passe,
  13x10=130 casse) ; GMAX=8 corrige par boucle de chunks dans les kernels
  groupés (min(ne,8) = DROP SILENCIEUX au-dela de 8, s2_expert_grouped.cu:827
  - piege trouve) et PAS GMAX=16 (shared 20->40 KiB, occupancy du chemin par
  defaut) ; batch/batch-mtp restent a 8 ; declencheur = match suffixe >= seuil
  (garde-fou contre le -12.7 % prose de la gate 1) ; defaut byte-identique par
  instanciations separees (T<=8 codegen inchange). Prochaine action : coder,
  build CUDA, tests de parite, banc ABBA sur sysai2.

2026-10-29 19:4x : GO OPERATEUR recu dans la session ("go") pour la PHASE 2,
  condition rappelée et acceptee : le bloc long n'est active QUE pendant une
  copie (declencheur HyperQwen) - sans cette garde la fenetre 8 seule coute
  -12.7 % en prose greedy (Gate 1). Branche f-qwen-lookup depuis main, knob
  opt-in (defaut byte-identique, CONTRIBUTING). Chantier : kVerifyMaxT 8->15
  (exec_[2][9], graphes, memoire par slot batch-mtp), source lookup longue via
  extra_draft_sources(), DraftPolicy voit le nouveau T sans forçage, garde de
  longueur de match, accord 2 tokens (lecon #4619 + _AGREE HyperQwen).
  C (selection stricte) : non retenu comme levier propre (+0.7 %).

2026-10-29 19:10-19:35 : GATE 1 EXECUTEE sur sysai2 (go operateur ; instance
  dsv41 lookup arretee a 19:0x avant le 1er boot - Kilo sans 8080 depuis).
  6 boots propres (ordre ABBA a1 b1 b2 a2 puis c1 c2), STRATA_SPEC_DEPTH=1,
  warmup jete, copie = document frais ~2 766 prompt/3 503 gen (2 segments
  cause thinking-cutoff, totalises), prose 400 tok. Binaire 0.1.52, avertissement
  VRAM 259 MiB identique a tous les boots. Chiffres moyens (2 boots/bras) :
    copie greedy : A 307.5 tok/s 3.55 tok/manche 94.4% | B 338.5 +10.1%
      4.70 t/m 93.4% | C 340.7 +10.8% 4.79 t/m 92.2%
    copie t=1    : A 265.9 3.10 | B 325.2 +22.3% (b2 380.6, bruit d'echantillonnage) | C 312.4 +17.5%
    prose greedy : A 152.2 1.94 66.7% | B 132.8 -12.7% 2.03 57.8% | C 138.3 -9.1% 67.1%
    prose t=1    : A 182.5 | B 181.0 (=) | C 173.2 (-5%)
  Histogramme profondeur (buckets 0-4, drafts MTP ; suffix = ligne separee) :
    A copie : test jusqu'au bucket 2 seulement (mtp_max_t=4), suffix 1779/1792.
    B copie : buckets 3-4 TESTES et ACCEPTES (8/11 8/8 ; 10/15 8/10) -> PAS
      d'effondrement au plafond ; B prose : bucket 3 15/19, bucket 4 9/13 (76-79%).
    C : chain active mais rare (12-18/574-591 fenetres copie, drafts 51/55 et
      79/81 acceptes = ~2% de l'offre ; prose 0-1/182-235 -> min 6 quasi inerte).
  LECTURE DES REGLES : "B plat ou effondrement a 5-6 -> STOP" NON VERIFIE (B
  gagne +10% copie, acceptation ~100% au fond). "B gagne copie, prose neutre"
  PARTIEL : prose greedy B = -12.7% NON neutre. C vs B (hors ABBA, a declarer) :
  +0.7% copie seulement, la selection stricte ne decale rien de notable.
  RECOMMANDATION soumise a l'operateur : GO phase 2 CONDITIONNELLE au declencheur
  HyperQwen (bloc long UNIQUEMENT pendant la copie - c'est exactement
  DFLASH_TOKENS=15) ; elargir kVerifyMaxT sans garde de declenchement paye la
  prose greedy. Limite : ABBA fait pour A/B seulement ; C compare sequentiellement.
  Fichiers : /tmp/opencode/qwen-lookup/gate1/ (logs bruts 6 boots, bench, parse).

2026-10-29 Gate 1 LIEU (consigne OPERATEUR dans la session) : "tout doit se
  faire sur sysai2 ; le test Qwen se fait sur sysai2, arreter DeepSeek (instance
  lookup dsv41 sur 8080) au prealable, en temps voulu". Le bras sysai1/P40 est
  ABANDONNE pour cette gate (RAM sysai1 = 5 Go dispo, service = modele de la
  session). sysai2 : strata.service INACTIF (watchdog inactif tant que le service
  ne l'est pas - verifie, il ne relance que si strata.service est active) ;
  5090+RAM occupes par l'instance dsv41 lookup (strata-ds4-test.json, demarree
  a la main, pas systemd) -> STOP de cette instance AUTORISE par l'operateur,
  fait juste avant le 1er boot. Fenetre = 8 boots ~15-20 min.
  Bras recales sur la prod sysai2 verifiee (strata-iq3_s.json : --prefill
  auto:16384 --spec 4 --spec-min-p 0.5 --kv k8v4 --kv-resident 32768 --ple-io ram
  --mtp mtp/rt --batch-mtp --parallel 2, suffix_draft defaut 3) :
  A = prod telle quelle -> fenetre 6 (4+2) ; B = --spec 6 --suffix-draft 3 ->
  fenetre 8 (plafond kVerifyMaxT) ; C = B + --lookup-chain 6 --lookup-chain-min 6.
  Ordre : ABBA (A B B A) puis BCCB. Par boot : warmup jete, copie greedy (doc
  frais ~3k tokens), copie t=1 (doc frais), prose greedy, prose t=1,
  STRATA_SPEC_DEPTH=1 ; chiffres lus dans le log moteur (lignes "generated in",
  "spec depth", "suffix drafts", "lookup chain" cumulrees par requete).
  Harness + logs : /tmp/opencode/qwen-lookup/gate1/.

2026-10-29 Gate 1 PREP (avant action, chiffres verifier sur place) : instruments
  confirmes dans le binaire sysai1 (strata 0.1.53, --help) : --suffix-draft,
  --lookup-chain K (opt-in, clamp 0-7), --lookup-chain-min, --spec. Defauts code
  (main 46c152a1 generate.cpp) : suffix_draft=3 (854), lookup_chain=0 (860) ;
  suffix : spec=min(spec+2,8) (3748-3751) ; chain : 3755-3759. ECART PLAN/REEL :
  la prod sysai1 = strata-iq3_s.json (pas pcie0) avec --spec 3 --spec-min-p 0.7
  --mtp rt, SANS --suffix-draft explicite ni --batch-mtp ; --pcie-frac 0.2.
  Bras effectifs : A = prod telle quelle -> fenetre 5 (3+2 suffix par defaut),
  B = --spec 6 --suffix-draft 3 -> fenetre 8 (PLAFOND), C = B + --lookup-chain 6
  --lookup-chain-min 6 (CORRECTION : le plan ecrivait "--lookup-chain-min 6" seul
  - sans --lookup-chain K le min est INERT, generate.cpp:3755). BLOCAGE :
  sysai1 RAM disponible 5 Go sur 92 (prod RSS ~82 Go, 2x P40 a 23,9/24,5 Go)
  -> 2e instance IMPOSSIBLE en cohabitation ; les bras exigent d'arreter
  strata.service sysai1 = le service qui sert le modele de CETTE session.
  Accord operateur DEMANDE avant toute action (regle n°0).

2026-10-29 : GATE 1 = EXPERIENCE SANS PATCH D'ABORD (consensus des deux analyses).
  Sur sysai1 (2x P40, ssh 10.12.75.12, see SKILL.md), moteur strata stock, arms :
    A : config prod telle quelle (--spec 4 --mtp --batch-mtp --suffix-draft 3) -> fenetre 6
    B : --spec 6 --suffix-draft 3 -> fenetre 8 (PLAFOND ACTUEL ; c'est la correction du bras B de DeepSeek)
    C : B + --lookup-chain-min 6 (selection plus stricte)
  Prompt copie (reproduire un document 2-4k tokens, greedy ET temperature=1)
  + prompt prose controle. Lire : tok/s, drafts offered/accepted (DONE/GET /metrics),
  STRATA_SPEC_DEPTH=1 histogramme d'acceptation par profondeur, lignes de boot.
  REGLE DE DECISION :
    - B plat ou acceptation effondree a profondeur 5-6 sur la copie -> STOP : la
      longueur n'est pas la contrainte ; noter, ne pas coder.
    - B gagne sur copie, prose neutre -> GO phase 2 : augmenter kVerifyMaxT
      (exec_[2][9] -> exec_[2][16], re-capture des graphes, memoire) + source lookup
      longue via extra_draft_sources + garde-fou (match >= X) + regle d'accord 2 tokens.
    - C > B sur accepted/offered sans perdre tok/manche -> la selection compte aussi.
  Ne PAS toucher au service strata de sysai2 sans accord (regle n°0). sysai1 :
  verifier d'abord ce qui y tourne (port 8080 ?) avec SKILL.md "strata-lab".
  Méthodo : boots propres, chiffres lus dans les logs, ABBA si A/B compares.

2026-10-29 : GATE 0 = RÈGLES RAPPELÉS par l'opérateur : AUCUN push, AUCUNE PR,
  AUCUNE publication sans demande + accord explicite dans la session. Tout est
  teste et valide avant d'ecrire quoi que ce soit en amont.

## Phase 2 (EN COURS depuis 2026-10-29 19:4x, branche f-qwen-lookup = main 46c152a1)

DESIGN v1 (cartographie explore + lecture directe des kernels) :
- Cap v1 = 12 (PAS 15) : K=10 experts/token (verify.cpp:843 exige k==10) et
  kResidentPlanMax=kMaxWindowEntries=128 threads -> 12x10=120 passe, 13x10=130
  casse (verify_kernels.cu:1306, expert_source.cpp:4791). 12 couvre l'essentiel
  du gain HyperQwen sans retoucher le scan du plan (4 warps, pack 16 bits).
- Knob opt-in env STRATA_SPEC_LONG=1 : au boot, max_t passe a 12 pour les
  verifiers du CHEMIN SERIAL (init generate.cpp:10091 via batch_max_t() -> cap
  runtime ; guard init verify.cpp:827 -> <= kVerifyLongT). Fenetres batch et
  batch-mtp RESTEES a 8 (conditions generate.cpp:12658, 6021 inchangees).
  Defaut = byte-identique : aucun chemin existant ne voit 12.
- Sizing : Verifier::init alloue deja tout en max_t (verify.cpp:873-1014).
  Ajouter constexpr kVerifyLongT=12 a cote de kVerifyMaxT=8 (ne PAS toucher
  kVerifyMaxT : il gouverne encore batch/GdnGroups/pm_drafts). Elargir (taille
  seule) : exec_[2][9]->[2][13], launched_, groups_[9], prof_t_*, rs_win_,
  rs_dev_ 9*L*8->*12, h_nf_/m_nf_, ple_rows stack, pl_ple_rows_, d_spec_,
  have[9], tableaux [8] (brow_, last_rows_, b_out_...), dp_*/t2_*[8], PW[8]
  laisser (pipeline hors scope), DraftPolicy kMaxT 8->12 (+ kShape[13]).
- Kernels : NOUVELLES instanciations template MAX_T=12 pour gdn_ab_multi /
  gdn_conv_ab_multi / gdn_state_replay ; dispatch : T<=8 garde les instanciations
  actuelles (codegen defaut inchange), 9..12 -> <12,false> ; guards n_tok a
  kVerifyLongT (verify_kernels.cu:1052,1066,1103,1118,1139,1165).
- PIEGE TROUVE : s2_expert_grouped.cu:827 GMAX=8 - min(ne,GMAX) DROP SILENCIEUX
  des entrees au-dela de 8 (commente "a longer window would drop entries without
  a word") : a T=12 un expert route par >8 tokens perdrait des entrees = FAUX.
  Fix retenu : boucle de chunks de GMAX dans gu/down_grouped (+ variantes _t) -
  a ne<=8 (defaut) une seule iteration, comportement identique ; PAS de GMAX=16
  (shared 20->40 KiB casserait l'occupancy du chemin par defaut).
- cpu::MAXT 8->12 (expert.hpp:143, pool.hpp, pool.cpp, kq_avx2) : capacite seule ;
  kMaxWindowEntries 128 tient (120<=128).
- Serve loop : le cap long ne s'applique que si sfx.last_match() >=
  STRATA_SPEC_LONG_MIN (defaut 12 - le gate 1 montre que la copie pure a des
  matchs longs ; seuil a regler au banc) - sinon regles actuelles a 8.
  gated_proposal force OFF quand knob on (gated::kRows=8, generate.cpp:2779-2780).
  DraftPolicy voit deja match (choose/chain/observe) - pas de forcage.
- Memoire/VRAM : graphs T=9..12 captures a la demande (lazy, verify.cpp:2610) +
  eviction OOM existante (instantiate_evicting 4272). Sur sysai2 boot prod deja
  a 259 MiB libres : surveiller evictions pendant la copie.
- REVISION DEEPSEEK reportee : l'agent "deepseek" pointe sur l'instance dsv41
  sysai2:8080 QUE NOUS AVONS ARRETEE pour la gate 1 -> API injoignable. La
  faire quand l'instance sera relancee (ou avant toute PR).

## Phase 2 - checklist du plan initial (adaptee : cap 12, voir DESIGN ci-dessus)

1. Branche f-qwen-lookup depuis main ; knob opt-in (ex. STRATA_SPEC_LONG=1) ;
   defaut byte-identique (CONTRIBUTING).
2. Chantier : kVerifyMaxT -> 15 (vérifier exec_[2][9] + batch graphs + mémoire par
   slot batch-mtp), source lookup longue branchée sur extra_draft_sources(),
   DraftPolicy voyant le nouveau T candidat (pas de forcage), garde-fou longueur
   de match (le rapport de match longueur via l'interface DraftSource si absent),
   accord lookup/MTP sur 2 premiers tokens.
3. Campagne de mesures sur sysai1 (P40 = la réalité Qwen) ET sysai2 (5090,
   strata.service éteint le temps des essais, relancé après) :
   identité greedy off/on (cmp octet pour octet, 300+ tokens), copie, prose,
   prompts courts, sampled t=1, RAM/VRAM/swap, batch.
4. Tests unitaires existants a faire passer : suffix_drafter_test, draft_policy_test,
   spec_prob_test, spec_verify_parity, verify_parity (CMakeLists:1710-1721).
   Build de CHAQUE backend touche (CUDA au moins ; HIP/SYCL si fichiers communs).
5. Revision soumise testee AVEC le patch applique (jamais "orthogonalement" - lecon
   de la PR #4619).

## Risques notés

- P40 sm61 : pas de bf16, bande passante bien plus basse que la 5090 ; nos chiffres
  dsv41 NE SE TRANSFERENT PAS. Coût 15 lignes ~1.9x par rapport a 8 : mesurer.
- batch-mtp multiplie la fenetre par slot ; policy apprise peut "refroidir" si on
  force des T longs.
- kVerifyMaxT touche des kernels : reconstruire CUDA (et HIP/SYCL si fichiers communs).
- Le service Qwen de sysai2 sert MOI (le modele d'opencode est SysAi1.Strata sur
  sysai1) : ne pas couper sysai1 a l'aveugle.

## Fichiers

- Materiaux analyses : /tmp/opencode/qwen-lookup/ (patch dsv41, facts.md,
  qwen-engine-map.md, analysis-deepseek-2.log) - survivent jusqu'au reboot,
  a recopier ici si besoin.
- BRUT DeepSeek brut : analysis-deepseek-2.log. Carte moteur : qwen-engine-map.md.

## Rapport final 2026-10-31 (Phase 2, non publie - accord requis)

PASSERELLE 1 (crash A) : RESOLU ETABLI PAR MESURE. Cause = last_tokens_[8] collant a n_vocab_/cs_ (verify.hpp:593,
boucle sans garde verify.cpp:3003) ; corruption mesuree AVANT fix (n_vocab = paire de tokens, cs contigu), 0 crash
repro x3 APRES fix (last_tokens_[kVerifyLongT] + kHistSlots kVerifyLongT). 6e survivante de la famille 8->12.
PASSERELLE 2 (identite) : prose B==BL byte-identique (le bloc long ne declenche pas hors copie, conforme au design).
Copie seed402 2200 mots : B deterministe cross-boot (temoin OK) ; BL DIVERGENT (token poubelle) - BUG OUVERT.
Bisect mesure : declencheur T=9 seul ; MTP hors cause (nomtp diverge aussi) ; batching hors cause (DEC_BATCH=0 diverge
aussi) ; contexte profond requis (mini-repro courte portee fenetres 9..12 = byte-identique ; selection QSA = identite
sous ~2051 cellules, reelle au-dela) ; NON DETERMINISTE meme boot (course ou lecture non initialisee, mecanisme NON
etabli). Hypothese amont documentee a verifier : non-reproductibilite expert-cache (arrondis CPU vs GPU, release 0.2.9
section Known problems, cote DeepSeek) - NON VERIFIE pour Qwen.
PARITE : shared_expert_multi 12 vs 8+4 vs 12x1 = byte-identique (test ajoute shared_expert_parity.cpp, EXECUTE PASS ;
le cas marque NON EXECUTE le 2026-10-30 est couvert). ctest -j2 : exactement les 6 echecs baseline, pas de regression.
ABBA VITESSE : NON EXECUTE (coupe pendant le boot B ; a relancer parallel=1 des deux bras, harness pret).
OUTILS AJOUTES : knob debug STRATA_SPEC_LONG_MAX (plafond fenetre longue, defaut inchange), instrumentation env-gated
STRATA_DBG_LAUNCH (stage_inputs), test shared_expert_multi, configs qw1-BL*.json, scripts gate1/.
RESTES NETTOYAGE AVANT PR : STRATA_DBG_DOT (verify.cpp:2823), STRATA_DBG_NAN (3542), g_dbg/STRATA_VERIFY_DEBUG,
backtrace() debug native_mmvq.cu:2310-2315, survivants chemin generate.cpp:18131-18139 (window/outv/accepted_hist
tailles o.spec avec T jusqu'a 12 - hors serveur), contrat kv_stream n_slots diminue pour n_q<=8 si max_t_=12 avec
KV-streaming actif (max-context >= ~20K : risque latent, non declenche dans nos runs mode 0).
AMONT : base 0.1.53 (46c152a1) ; v0.2.9/0.1.55 (c62d5e3a) = 239 commits, conflits prevus (generate.cpp x14 amont,
verify.cpp x6) ; rebase DECIDE au moment PR (same-day compare amont), pas pendant l'isolement du bug.

## Revision du rapport final 2026-10-31 (reprise 2) - remplace les sections PASSERELLE 2 / ABBA ci-dessus

BUG DE DIVERGENCE : N'EST PAS UN BUG DE NOTRE PATCH. Mechanisme ETABLI PAR MESURE (Decision Log reprise 2,
TAP#5 + M1 + M2) : le moteur Qwen n'est PAS reproductible a temperature 0 a cause de l'expert-cache VRAM
(OBLIGATOIRE pour verify : verify.cpp:832-838) dont le melange hits GPU / misses CPU a des arrondis legerement
differents (mesuree : 9.1e-06..4.6e-05 de max rel sur les premiers taps touches, native_expert_parity documente
"few 1e-3 relative" entre chemins CPU et GPU, R4.2h generate.cpp:7716-7718 documente la famille) ; l'eviction LRU
et le DraftPolicy (couts = round_ms mesures, draft_policy.hpp:13-15) dependent du wall-clock -> en contexte profond
(> ~2051 cellules) la selection QSA top-k bascule pres des frontieres -> cascade -> flip de token. MESURES CLES :
(a) bras B SANS knob : 3 boots sans instrument -> 2 streams distincts (b1 != b2=b3 octet pour octet, divergence
byte 7447) - le defaut lui-meme flippe ; (b) BL cap12 : 3 boots -> 3 streams distincts ; (c) a taps identiques
(t9==b1, t11==b2 byte-identical) - le tap est passif ; (d) a shape de fenetre IDENTIQUE et tokens identiques,
floats differents quand meme (pos 2960 layer 43, t9 vs t11) ; (e) --expert-cache-cpu-order ne mitige pas (l4!=l5).
Fenetre longue = AMPLIFICATEUR (taux de flip et modes plus varies), pas la cause. Le "cap 9 suffit" anterieur est
REINTERPRETE : cap 8 AU KNOB n'avait jamais ete teste ; t10 (cap8) = 1 boot propre mais taux non mesure.
ABBA VITESSE relancee (etape 3, parallel=1, seed 401, 4 boots B BL BL B, medians de paires) : BL NEGATIVE
(copie -25.9 % pair / -11.2 % clean ; prose -8.1 % / -2.4 %) - le gain HyperQwen n'est PAS reproduit a parallel=1.
OUTILS AJOUTES (reprise 2) : tapdiff/tapwin/tapmatch/tapstream/taprow.py, probe_tapdbg.sh (taps 0..46 + DBG),
probe_notap.sh, probe_notapco.sh, abba.sh ; STRATA_DBG_LAUNCH etendu (pos0,T par stage_inputs - instrumentation
env-gated, hors chemin par defaut).
DECISION OPERATEUR ATTENDUE AVANT PR : publier la fenetre longue comme EXPERIMENTALE avec ces chiffres (vitesse
negative + moteur non reproductible), ou retirer le chantier BL et ne garder que les correctifs de la famille
8->12 (last_tokens_, kHistSlots, kTqMaxTokens, pl_ple_rows_, nsw.q8_1 offset, GMAX chunking) deja validates.
NETTOYAGE (etape 4) : fait le 31/10 reprise 2 - voir entrees Decision Log. RESTES CONNUS AVANT PR : generate.cpp:18131-18139
(window/outv/accepted_hist tailles o.spec vs T 12, chemin generate pas serveur) ; contrat kv_stream n_q<=8 si
max_t_=12 avec KV-streaming (prod 262144, mode 1, jamais declenche dans nos runs) ; KL/quality suite, builds
HIP/SYCL, wrappers mac.


2026-10-30 11:3x : CAUSE DU SEGFAULT FENETRE LONGUE TROUVEE (mesuree, pas statique).
  Symptome : SIGSEGV deterministe dans cudaGraphLaunch (libcuda+0x355392, mov (%rdx))
  au premier launch d'une fenetre 11/12 ; parfois apres des milliers de tokens.
  A/B test : config BL avec parallel=2 (--batch 2, comme prod) -> crash systematique ;
  parallel=1 seul changement -> 9 requests complets (dont 3 avec le fix q8_1),
  8 launches T=11 + 27 T=12, 0 crash, 242-317 tok/s. mecanisme exact (race entre
  les sessions de slots du batch et la capture des fenetres >8 sur cs_) = NON
  CONFIRME (analyse statique only) ; le fait mesure = correlation batch2/crash,
  batch1/stabilite. Consequence phase 2 : le knob long ne marche qu'avec
  parallel=1 ; a documenter et a faire valider en amont.
  Faux-positifs elimines pendant la chasse : --max-context, marge VRAM
  (939 MiB libre = crash aussi), MALLOC_CHECK_, STRATA_HEAD_MIX_MULTI=0,
  STRATA_FUSE_HEAD_GR=0, saut de cudaGraphUpload. Le debug additif
  cudaGraphDebugDotPrint pollue lastError -> exit(1) du check_launch d'apres
  (fausse piste "copy_from_mapped_multi invalid argument").
  BUG DE JUSTESSE TROUVE ET CORRIGE au passage : shared_expert_multi chunke
  (passe cb>=8) recevait nsw.q8_1 sans offset : les rows 8..11 relisaient les
  colonnes q8_1 0..cn-1 (entrees ffn partagees fausses sur ces rows -> decisions
  de verify fausses = losslessness compromise). Fix : nsw2.q8_1 += cb*(N/32)*36.
  Non couvert par les tests de parite existants (a ajouter : shared_expert_multi
  n=12 vs 8+4 passes, marque NON EXECUTE pour l'instant).
  PROCHAINES ETAPES (consentement operateur deja donne pour la phase 2) : retirer
  tout le debug temporaire (prints long-dbg, checks additionnels, upload-skip,
  handler STRATA_SEGV_HANDLER), rebuild, cteste cible, puis identite BL/B/B seed
  401 avec parallel=1 et bench ABBA B vs BL (B a remesurer avec parallel=1, sinon
  le comparatif est fausse - les bras gate 1 tournaient en parallel=2).

### Decision Log 2026-10-31 (reprise 3)
- AUDIT (Phase A) : empreintes revérifiées — b1==s1==s2==t9 (0e9aba12) et b2==b3==s3==s4==t11 (6a182011) CONFIRMEES par sha256 ; divergence par prefix byte 7447. ECARTS trouves : (1) engine/strata.pre-patch est engine 0.1.52 (log "session is up (engine 0.1.52)"), PAS 0.1.53 — les bras s1..s4 etaient donc 0.1.52, pas le stock 46c152a1 ; (2) references de lignes decalees apres nettoyages : remap expert-cache generate.cpp:5105->5107-5109, cache_base 7710->7730, win_cap 18254->18268 ; (3) M2 : l4=855 octets (diff l5 des le byte 852), l5=7447 — les "4689/6000" ne correspondent pas aux fichiers ; (4) ctest re-execute : exactement les 6 baseline (93 ple_parity, 104 platform_memory_test, 187 expert_parity, 188 pool_test, 195 isa_guard_check, 198 cuda_spill_guard). ABBA retrouve dans gate1/logs/a{1..4}.server.out : medians pairs B {404.0,397.6}=400.8 vs BL {238.0,355.8}=296.9 (-25.9%) ; note : a2 BL copie = 2694/2718 tokens (stop) — vitesse BL contaminee par la divergence elle-meme.
- DECISION : (a) construire un binaire stock reel de 46c152a1 via git stash -> build -> cp engine/strata.base -> stash pop -> rebuild patched (pre-patch 0.1.52 non touche) ; (b) relancer q24 sur port 8092 (la serie d'echecs "server exited 2" = conflit de port 8091 laisse par l'instance precedente, server.py:152) avec stock=engine/strata.base ; (c) si divergence patched-vs-stock : controle stock-vs-stock ; (d) GPU verifie libre avant/apres.
- q24 (suite 24 prompts greedy temp 0, tools/dgx_quality24.py corrige KEY+ROOT, port 8092/8093/8094, GPU verifie vide avant/apres, tu par PID, aucun orphelin) :
  * patched(engine/strata 0.1.53) vs BASE reel (engine/strata.base, construit via git stash de 46c152a1, --version 0.1.53) : 11/24 identiques — 13 divergences, 1er byte divergent entre 20 et 293.
  * CONTROLE base-vs-base : 23/24 (1 flip prompt 23) — bruit propre du stock ~4%.
  * CONTROLE patched-vs-patched : 24/24 — le patched est DETERMINISTE a temp 0 sur ces prompts courts.
  * CONFIG identique prouvee (diff = exe+log seulement). Conclusion : ECART MAJEUR — le patch modifie le comportement du chemin DEFAUT (knob OFF) en prose courte ; contredit la claim "defaut byte-identical" (l'identite b1==s1 ne tenait que sur la copie longue et contre 0.1.52, pas contre le base 0.1.53). La non-reproductibilite "expert-cache" attribuee au stock ne se voit pas ici (23-24/24 cross-boot sur prompts courts) : les flips de copie exigeaient la zone de decrochage profonde.
  * ecart d'audit confirme : strata.pre-patch = 0.1.52 (pas 0.1.53) ; les s1..s4 etaient 0.1.52.
- DECISION SUIVANTE : bisect statique puis, si besoin, par zones (verify.cpp/hpp, generate.cpp, kernels cuda, kernels cpu, spec) contre la reference patched enregistree (q24-pp.json) avec un boot unique par variante. But : determiner si la divergence defaut est un BUG du patch ou un correctif qui change volontairement le defaut (nsw.q8_1 offset, GMAX) — sans ca, la condition mainteneur "opt-in, defaut byte-identical" est echouee.
- BISECT DEFAUT (GPU, reference = q24-pp.json cote patched, boot unique par variante, port 8095+, kill PID, GPU vide avant/apres) : statique a ecarte sfx.propose/long_gate/agree2/mT (tous no-op avec knob OFF). Suspects restants : kHistSlots=kVerifyLongT (generate), layout xq_/xil_ + q_cols/mm_cols (verify.cpp), kernels s2_expert_grouped/verify_kernels/cpu. Variante V1 = generate.cpp revert a 46c152a1 (restore depuis /tmp/gen.patched.cpp apres) ; puis V2 verify.cpp+hpp ; puis V3 kernels.
- BISECT DEFAUT TERMINE (V1-V7, 1 boot par variante, reference = reponses enregistrees; tous les serveurs tues par PID, GPU verifie vide apres chaque run) :
  * V1 generate.cpp revert -> 24/24 vs patched (innocente) ; V2 verify.cpp+hpp revert -> 24/24 (innocente) ; V3 kernels cpu/cuda (sauf verify_kernels.*) revert -> 24/24 (innocentes) ; V4 draft_policy revert -> 24/24 (innocente) ; accident consigne: `git checkout f-qwen-lookup -- draft_policy` a ecrase le WIP (non commit) -> restaure a l'identique depuis le diff sauvegarde (2 lignes kMaxT, 3 lignes kShape), verifie.
  * V5 = verify_kernels.cu revert a 46c152a1 + stub preload -> 11/24 vs patched ET 24/24 vs base : LA divergence defaut vient de verify_kernels.cu.
  * V6 = base + cases 9..12 seuls + stub -> 24/24 vs base : les instantiations supplementaires ne changent pas le defaut.
  * V7 = V6 + seul remplacement des 3 gardes de borne kVerifyMaxT->kVerifyLongT (semantique identique pour n_tok<=8, chemin d'erreur only) -> 11/24 vs base : la divergence revient.
  * CONCLUSION: le defaut greedy est SENSIBLE AU CODE LAYOUT du launcher (changement sans effet semantique possible -> course latente cote host sur le staging des arguments/conv_blocks, ou UB dans la chaine gdn; cohérent avec la famille "capture/libcuda race" deja observee). Le patch ne casse pas la semantique par sa logique: il DEPLACE le timing et REVELE une course preexistante. A confirmer (Valgrind/TSAN hors portee 5090; a designer comme finding amont).
  * Consequence PR: la condition "defaut byte-identical" est ECHOUEE en pratique (11/24) tant que la course n'est pas corrigee — meme un changement purement decoratif du launcher change les reponses. C'est une donnee pour la decision de portee, pas une correction supplementaire.

### Fin de session 2026-10-31 (reprise 3) — ETAT DE CLOTURE
- Decision: ARRET du chantier BL sur avis operateur. Bilan: aucun gain mesure (ABBA: copie -25.9%, prose -8.1%), suite qualite patched-vs-base 11/24 (regression defaut), bisect V1-V7: la divergence defaut vient de verify_kernels.cu (course latente; V7 = seul changement de garde de borne = 11/24). Rien committe, rien pousse.
- Arbre: 46c152a1 + 19 fichiers modifies non commites (WIP complet, intact). engine/strata = patched 8ffadf51; engine/strata.base = stock reel 46c152a1 612dc33e; engine/strata.pre-patch = release 0.1.52 (ne pas confondre avec le stock de la base). build/strata reconstruit depuis l'arbre patche (non byte-identique a engine/strata: link non deterministe, fonctionnellement identique).
- Artefacts gardes: q24-out/ctrl/pp.json (patched vs base, base vs base, patched vs patched), q24-V1..V7.json + logs, gate1/ (taps, b/s/t/a), strata.V*.bin hors depot. tmpfs 70% — purger uniquement sur decision.
- Prochaine session: lire cette cloture + Decision Log reprise 3; questions ouvertes = portee (retirer BL vs finding course latente), commit local (accord requis), rebase vers v0.2.9/0.1.55 eventuel (upstream a des fenetres 16 rows - risque de doublon).
