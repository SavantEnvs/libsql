SELECT json_extract('{"a":[1,2,{"b":3}]}','$.a[2].b'), json_array(1,'x',null), json_set('{}','$.k',5), json_group_array(value) FROM json_each('[1,2,3]');
