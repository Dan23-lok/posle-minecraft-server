# Проверка фонарей для Forge 1.20.1

11 октября 2026 г. Тесты проведены только в изолированных копиях `D:\1-Game\support\staging-dynamic-flashlight-20261011` и `D:\1-Game\support\staging-dual-flashlight-20261011`. Forge 47.4.10, Java 17, локальное подключение `127.0.0.1`. Игровой мир — копия QA-мира, не действующий мир сервера. После проверки оба сервера сохранены и остановлены: тестовых Java-процессов и слушателей на портах 25598/25599 нет.

## Проверенные файлы

| Мод | Официальная версия | Лицензия и загрузка | SHA-512 скачанного JAR |
| --- | --- | --- | --- |
| Dynamic Flashlight 2.1.0, Forge 1.20.1 | [страница версии](https://modrinth.com/mod/dynamic-flashlight/version/dkQtiEhc) | [проект](https://modrinth.com/mod/dynamic-flashlight) указывает ARR, клиент и сервер; [оригинальный CDN](https://cdn.modrinth.com/data/SemszBhn/versions/dkQtiEhc/flashlight-2.1.0-forge-1.20.1.jar). JAR не включать в распространяемый ZIP, загрузку выполнять с оригинального URL с проверкой хеша. | `45e97d9f5263331a3cd3787b64bbfbf5e75fd591d30847e73b4816a921d66bb2acb03f9b1a4ccadd64289574fac0a434515c9fb36d701ea32ea191d828611530` |
| Powered Flashlight 1.0.0, Forge 1.20.1 | [страница версии](https://modrinth.com/mod/powered-flashlight/version/1tpZnh9i) | [проект](https://modrinth.com/mod/powered-flashlight) указывает LGPL-3.0-or-later, клиент и сервер; [оригинальный CDN](https://cdn.modrinth.com/data/cidr24jQ/versions/1tpZnh9i/powered_flashlight-forge-1.20.1-1.0.0.jar). | `c1b64ff882b1b2f4f555874fed496620ca4d67093fa6eb447046499f0d0edc80a413d55d98b6e131bf1bc54aad1fe789e7fdd87cae3c319b2b2e7276b7ee9edc` |

Оба хеша вычислены локально от тестовых JAR. На официальных страницах указан Forge 1.20.1 и установка на обе стороны. Права на распространение Dynamic Flashlight отдельно не получались.

## Игровые наблюдения

Камера фиксировалась серверными `/tp` и `/data get entity ... Pos/Rotation`. Ночь зафиксирована, без движения между снимками каждой пары. Белая тестовая стена расположена на 18,5 блока от игрока. В ходе теста были рассчитаны средние значения grayscale 0–255 в одинаковых областях парных кадров, но точные границы этих областей не записаны. Поэтому численные значения ниже нельзя независимо воспроизвести; они служат ориентиром, а вывод следует проверять по исходным F2-кадрам.

| Условия | Снимки F2 | Изменение яркости стены / земли |
| --- | --- | --- |
| Без шейдера, с True Darkness Biomes, фонарь выключен/включён | `dynamic-flashlight-low-far-18m-off.png`, `dynamic-flashlight-low-far-18m-on.png` | Стена 0,92→24,58; земля 0→60,72; небо 12,63→13,07. Направленная подсветка стены и земли заметна. |
| DMS 1.0.3 + True Darkness Biomes | `dynamic-flashlight-dms-far-18m-off.png`, `dynamic-flashlight-dms-far-18m-on.png` | Стена 0,92→1,83; земля 0→45,98. Ближняя земля светится, дальняя стена почти не видна. |
| DMS 1.0.3 без True Darkness Biomes | `dynamic-flashlight-dms-no-tdb-far-off.png`, `dynamic-flashlight-dms-no-tdb-far-on.png` | Стена 0,92→4,59; земля 1,41→58,70. Удаление True Darkness не вернуло выраженную дальнюю подсветку. |

Для лесной сцены снимки `dynamic-flashlight-low-off/on.png` и `dynamic-flashlight-dms-off/on.png` показывают свет на ближайших листьях и земле в направлении взгляда. В безшейдерном варианте при первом включении NBT фонаря сменился с `{Charge:3000,On:0b}` на `{Charge:2928,On:1b}`. С DMS после включения было `{Charge:2941,On:1b}`. Лог Oculus подтвердил `Using shaderpack: DMS 1.0.3.zip` и создание pipeline. В кадрах подтверждена освещённость блоков; видимый объёмный конус в воздухе этим тестом не доказан.

Проверка преграды: после установки глухой стены число временных блоков света за ней в выбранной области изменилось с 2 на 0 (`fill ... replace flashlight:temporary_light`); кадр `dynamic-flashlight-low-wall-on.png`. Это проверяет серверные блоки света в одной сцене, а не все варианты утечки клиентского рендера. Воду отдельно не тестировали.

С одним игроком и одним активным Dynamic Flashlight сервер выдавал 20 TPS; выборки `/forge tps` показали среднее время тика примерно 1,5–1,8 мс (в co-install около 2,1 мс). Клиентский компьютер имел RTX 3060; одиночный кадр F3 показывал около 59 FPS. Это не тест слабых ПК, нескольких игроков или нагрузки катастроф.

## Совместимость клиента и сохранений

Клиент с Powered Flashlight вместо Dynamic, при остальном аналогичном наборе модов, попробовал войти на сервер с Dynamic по `127.0.0.1:25598`. FML в логе клиента ответил: `Channels [powered_flashlight:network] rejected their server side version number`; затем `Terminating connection with server, mismatched mod list`. Замена мода только на сервере не подходит: клиентам нужен соответствующий набор при выпуске.

В отдельной копии с **обоими** JAR сервер и клиент Forge 47.4.10 загрузились и соединились. В инвентаре одновременно были `flashlight:flashlight` и `powered_flashlight:flashlight`. Снимки `dual-flashlight-dynamic-off/on.png` подтверждают работу Dynamic; после включения его NBT был `{Charge:2922,On:1b}`. Затем слот Dynamic был явно заменён на выключенный предмет `{Charge:3000,On:0b}` для отдельного теста Powered. Снимки `dual-flashlight-powered-off/on.png` показывают свет Powered поблизости; после включения его NBT был `{active:1b,energy:0}` при тестовой настройке `energy_drain_per_tick=0`. После сохранения, полного перезапуска сервера и повторного входа оба ID и эти NBT сохранились в тестовом playerdata.

При первом запуске co-install на мигрированной копии мира сервер предупредил: `Registry minecraft:block: Object did not get ID it asked for. Name: powered_flashlight:light Expected: 1121 Got: 1120`. На первом standalone Dynamic запуске копии Forge также сообщил о перенумерации `flashlight:temporary_light`, `flashlight:flashlight` и `flashlight:battery`. Сервер продолжил работу, при следующем co-install запуске предупреждение не повторилось. **Перед переносом на действующий мир нужна проверка его отдельной полной копии с резервной копией и сравнением инвентарей/блоков после перезапуска.** Текущий опыт не доказывает сохранность уже выданных предметов в настоящем мире. Во время первого co-install запуска клиент также записал OpenGL `GL_INVALID_OPERATION`; игра продолжила работу, причину отдельно не исследовали.

Итог теста: вариант с обоими модами технически возможен в QA-копии и сохраняет тестовые предметы при перезапуске. Dynamic лучше освещает дальнюю стену без шейдера, но с DMS дальний эффект заметно слабее. Перенос на действующий сервер и обещания по слабым ПК требуют отдельных проверок.


## Исходные снимки F2

- [dynamic-flashlight-low-off.png](./dynamic-flashlight-low-off.png)
- [dynamic-flashlight-low-on.png](./dynamic-flashlight-low-on.png)
- [dynamic-flashlight-low-far-18m-off.png](./dynamic-flashlight-low-far-18m-off.png)
- [dynamic-flashlight-low-far-18m-on.png](./dynamic-flashlight-low-far-18m-on.png)
- [dynamic-flashlight-low-wall-on.png](./dynamic-flashlight-low-wall-on.png)
- [dynamic-flashlight-dms-off.png](./dynamic-flashlight-dms-off.png)
- [dynamic-flashlight-dms-on.png](./dynamic-flashlight-dms-on.png)
- [dynamic-flashlight-dms-far-18m-off.png](./dynamic-flashlight-dms-far-18m-off.png)
- [dynamic-flashlight-dms-far-18m-on.png](./dynamic-flashlight-dms-far-18m-on.png)
- [dynamic-flashlight-dms-no-tdb-far-off.png](./dynamic-flashlight-dms-no-tdb-far-off.png)
- [dynamic-flashlight-dms-no-tdb-far-on.png](./dynamic-flashlight-dms-no-tdb-far-on.png)
- [dual-flashlight-dynamic-off.png](./dual-flashlight-dynamic-off.png)
- [dual-flashlight-dynamic-on.png](./dual-flashlight-dynamic-on.png)
- [dual-flashlight-powered-off.png](./dual-flashlight-powered-off.png)
- [dual-flashlight-powered-on.png](./dual-flashlight-powered-on.png)
