# yobirin — 作業の決まり

このリポジトリは 2 台の Mac から直す。

## 開発を始める前に、必ず更新を確かめる

コードに手を入れる前に毎回:

1. `git fetch origin`
2. `git log --oneline HEAD..origin/main` で、向こうの PC が上げたコミットがないか見る
3. あれば `git pull --rebase origin main` で取り込んでから始める（手元に未コミットの変更があるなら、先に commit してから）
4. 取り込んだら `make install` で入れ直してから作業する

## push の前にも、もう一度確かめる

push の直前にも `git fetch origin` → `git log --oneline HEAD..origin/main` を見て、先行していれば rebase してから push する。
