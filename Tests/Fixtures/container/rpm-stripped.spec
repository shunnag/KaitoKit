Name: kaito-rpm6
Version: 1.0
Release: 1
Summary: KaitoKit RPM fixture
License: MIT
BuildArch: noarch

%description
KaitoKit 所有の stripped cpio 検証用データ。

%install
mkdir -p %{buildroot}/usr/share/kaito-rpm6
cd %{buildroot}/usr/share/kaito-rpm6
awk 'BEGIN { for (i = 0; i < 257; i++) print "KaitoKit stripped RPM payload 0123456789" }' > large.txt
: > empty.txt
printf '日本語の RPM fixture\n' > 日本語.txt
ln -s 日本語.txt link.txt
printf 'hard link content\n' > hard-a.txt
ln hard-a.txt hard-b.txt
ln hard-a.txt hard-c.txt
printf 'partial hard link content\n' > partial-a.txt
ln partial-a.txt partial-b.txt
ln partial-a.txt partial-z-ghost.txt
printf 'ghost content\n' > standalone-ghost.txt
chmod 644 *.txt
touch -t 202609220000.00 *.txt .
touch -h -t 202609220000.00 link.txt

%files
%defattr(-,root,root,-)
%dir /usr/share/kaito-rpm6
/usr/share/kaito-rpm6/large.txt
/usr/share/kaito-rpm6/empty.txt
/usr/share/kaito-rpm6/日本語.txt
/usr/share/kaito-rpm6/link.txt
/usr/share/kaito-rpm6/hard-a.txt
/usr/share/kaito-rpm6/hard-b.txt
/usr/share/kaito-rpm6/hard-c.txt
/usr/share/kaito-rpm6/partial-a.txt
/usr/share/kaito-rpm6/partial-b.txt
%ghost /usr/share/kaito-rpm6/partial-z-ghost.txt
%ghost /usr/share/kaito-rpm6/standalone-ghost.txt
