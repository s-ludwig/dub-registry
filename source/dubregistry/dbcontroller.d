/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.dbcontroller;

import std.array;
import std.algorithm;
import std.exception;
//import std.string;
import std.uni;
import vibe.vibe;


class DbController {
	private {
		MongoCollection m_packages;
	}

	this(string dbname)
	{
		auto db = connectMongoDB("127.0.0.1").getDatabase(dbname);
		m_packages = db["packages"];

		// update package format
		foreach(p; m_packages.find()){
			if( p.branches.type == Bson.Type.Object ){
				Bson[] branches;
				foreach( b; p.branches )
					branches ~= b;
				p.branches = branches;
			}
			m_packages.update(["_id": p._id], p);
		}

		repairVersionOrder();
	}

	void addPackage(ref DbPackage pack)
	{
		enforce(m_packages.findOne(["name": pack.name], ["_id": true]).isNull(), "A package with the same name is already registered.");
		pack._id = BsonObjectID.generate();
		m_packages.insert(pack);
	}

	DbPackage getPackage(string packname)
	{
		auto bpack = m_packages.findOne(["name": packname]);
		enforce(!bpack.isNull(), "Unknown package name.");
		return deserializeBson!DbPackage(bpack);
	}

	auto getAllPackages()
	{
		return m_packages.find(Bson.EmptyObject, ["name": 1]).map!(p => p.name.get!string)();
	}

	auto getUserPackages(BsonObjectID user_id)
	{
		return m_packages.find(["owner": user_id], ["name": 1]).map!(p => p.name.get!string)();
	}

	void removePackage(string packname, BsonObjectID user)
	{
		m_packages.remove(["name": Bson(packname), "owner": Bson(user)]);
	}

	void setPackageErrors(string packname, string[] error...)
	{
		m_packages.update(["name": packname], ["$set": ["errors": error]]);
	}

	void addVersion(string packname, DbPackageVersion ver)
	{
		m_packages.update(["name": packname], ["$push": ["versions": ver]]);
	}

	void updateVersion(string packname, DbPackageVersion ver)
	{
		m_packages.update(["name": packname, "versions.version": ver.version_], ["$set": ["versions.$": ver]]);
	}

	void addBranch(string packname, DbPackageVersion ver)
	{
		assert(ver.version_.startsWith("~"));
		m_packages.update(["name": packname], ["$push": ["branches": ver]]);
	}

	void updateBranch(string packname, DbPackageVersion ver)
	{
		m_packages.update(["name": packname, "branches.version": ver.version_], ["$set": ["branches.$": ver]]);
	}

	bool hasVersion(string packname, string ver)
	{
		auto packbson = Bson(packname);
		auto verbson = serializeToBson(["$elemMatch": ["version": ver]]);
		auto ret = m_packages.findOne(["name": packbson, "versions" : verbson], ["_id": true]);
		return !ret.isNull();
	}

	bool hasBranch(string packname, string ver)
	{
		auto packbson = Bson(packname);
		auto verbson = serializeToBson(["$elemMatch": ["version": ver]]);
		auto ret = m_packages.findOne(["name": packbson, "branches" : verbson], ["_id": true]);
		return !ret.isNull();
	}

	auto searchPackages(string[] keywords)
	{
		string[] barekeywords;
		foreach( kw; keywords ){
			kw = kw.strip();
			//kw = kw.normalize(); // separate character from diacritics
			string[] parts = splitAlphaNumParts(kw.toLower());
			barekeywords ~= parts;
			barekeywords ~= join(barekeywords);
		}
		return m_packages.find(["searchTerms": ["$in": keywords]]).map!(b => deserializeBson!DbPackage(b))();
	}

	private void repairVersionOrder()
	{
		foreach( bp; m_packages.find() ){
			logDebugV("pack %s", bp.toJson());
			auto p = deserializeBson!DbPackage(bp);
			sort!((a, b) => vcmp(a, b))(p.versions);
			m_packages.update(["_id": p._id], ["$set": ["versions": p.versions]]);
		}
	}
}

struct DbPackage {
	BsonObjectID _id;
	BsonObjectID owner;
	string name;
	Json repository;
	DbPackageVersion[] versions;
	DbPackageVersion[] branches;
	string[] errors;
	string[] categories;
	string[] searchTerms;
}

struct DbPackageVersion {
	BsonDate date;
	string version_;
	Json info;
}


bool vcmp(DbPackageVersion a, DbPackageVersion b)
{
	return vcmp(a.version_, b.version_);
}

bool vcmp(string va, string vb)
{
	try {
		auto aparts = linearizeVersion(va);
		auto bparts = linearizeVersion(vb);

		foreach( i; 0 .. min(aparts.length, bparts.length) )
			if( aparts[i] != bparts[i] )
				return aparts[i] < bparts[i];
		return aparts.length < bparts.length;
	} catch( Exception e ) return false;
}


private int[] linearizeVersion(string ver)
{
	import std.conv;
	static immutable suffixes = ["alpha", "beta", "rc"];
	auto parts = ver.split(".");
	int[] ret;
	foreach( p; parts ){
		ret ~= parse!int(p);

		bool gotprefix = false;
		foreach( i, suffix; suffixes ){
			if( p.startsWith(suffix) ){
				p = p[suffix.length .. $];
				if( p.length ) ret ~= cast(int)i*10000 + to!int(p);
				else ret ~= cast(int)i*10000;
				gotprefix = true;
				break;
			}
		}
		if( !gotprefix ) ret ~= int.max;
	}
	return ret;
}

private string[] splitAlphaNumParts(string str)
{
	string[] ret;
	while(str.length){
		while(!str.front.isIdentChar()) str.popFront();
		if( !str.length ) break;
		size_t i = 0;
		while(i < str.length && str[i].isIdentChar()) i++;
		ret ~= str[0 .. i];
		str = str[i .. 0];
	}
	return ret;
}

private bool isIdentChar(dchar ch)
{
	return std.uni.isAlpha(ch) || std.uni.isNumber(ch);
}