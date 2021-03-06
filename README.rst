phpList - Email campaign management
===================================

`phpList`_ is the world's most popular open source email campaign
manager. It's a one-way email announcement delivery system that's great
for newsletters, publicity lists, notifications, and many other uses. It
has a web interface lets you write and send messages, and manage phplist
over the internet.

This appliance includes all the standard features in `TurnKey Core`_,
and on top of that:

- phpList configurations:
   
   - Installed from upstream source code to /var/www/phplist

      **Security note**: Updates to phpList may require supervision so
      they **ARE NOT** configured to install automatically. See `phpList
      documentation`_ for upgrading.

- SSL support out of the box.
- `Adminer`_ administration frontend for MySQL (listening on port
  12322 - uses SSL).
- Postfix MTA (bound to localhost) to allow sending of email (e.g.,
  password recovery).
- Webmin modules for configuring Apache2, PHP, MySQL and Postfix.

Credentials *(passwords set at first boot)*
-------------------------------------------

-  Webmin, SSH, MySQL: username **root**
-  Adminer: username **adminer**
-  phpList: username **admin**


.. _phpList: https://www.phplist.com/
.. _TurnKey Core: https://www.turnkeylinux.org/core
.. _phpList documentation: https://www.phplist.org/manual/ch031_upgrading.xhtml
.. _Adminer: https://www.adminer.org/
